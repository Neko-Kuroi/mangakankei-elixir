defmodule PlatformExWeb.AuthController do
  @moduledoc """
  認証まわりの API。URL・状態コード・文言・検証の順序は
  Python 版 main.py の /api/auth/* と揃える。
  入力検証の 422 は pydantic v2 の形（detail の配列）を模す。
  """
  use PlatformExWeb, :controller

  alias PlatformEx.{Accounts, Admin, Auth}
  alias PlatformExWeb.RateLimit

  plug PlatformExWeb.Plugs.CurrentUser when action in [:me, :grants, :declare_adult]

  # ---------------------------------------------------------------------------
  # POST /api/auth/signup（制限：3/hour）
  # ---------------------------------------------------------------------------

  def signup(conn, _params) do
    case validate_signup(conn.body_params) do
      {:error, errors} ->
        conn |> put_status(422) |> json(%{detail: errors})

      {:ok, attrs} ->
        with :ok <- RateLimit.check(conn, "signup", 3_600_000, 3) do
          case Accounts.register_user(attrs) do
            {:ok, _user} ->
              json(conn, %{message: "ユーザー登録が完了しました。ログインしてください。"})

            {:error, message} ->
              conn |> put_status(400) |> json(%{detail: message})
          end
        else
          {:error, conn} -> conn
        end
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/auth/token（ログイン。フォーム形式、制限：5/minute）
  # ---------------------------------------------------------------------------

  def login(conn, _params) do
    body = if form_content?(conn), do: conn.body_params, else: %{}

    case validate_login(body) do
      {:error, errors} ->
        conn |> put_status(422) |> json(%{detail: errors})

      {:ok, %{"username" => username, "password" => password}} ->
        with :ok <- RateLimit.check(conn, "login", 60_000, 5) do
          case Accounts.authenticate(username, password) do
            {:ok, user} ->
              json(conn, %{
                access_token: Auth.Token.issue(user.id),
                token_type: "bearer",
                username: user.username
              })

            {:error, status, message} ->
              conn |> put_status(status) |> json(%{detail: message})
          end
        else
          {:error, conn} -> conn
        end
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/auth/me
  # ---------------------------------------------------------------------------

  def me(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      id: user.id,
      username: user.username,
      email: user.email,
      account_type: user.account_type || "author",
      is_admin: Admin.admin?(user.username),
      adult_declared_at: user.adult_declared_at
    })
  end

  # ---------------------------------------------------------------------------
  # GET /api/auth/grants
  # ---------------------------------------------------------------------------

  def grants(conn, _params) do
    json(conn, Accounts.grants_for_user(conn.assigns.current_user))
  end

  # ---------------------------------------------------------------------------
  # POST /api/auth/declare-adult
  # ---------------------------------------------------------------------------

  def declare_adult(conn, _params) do
    {:ok, user} = Accounts.declare_adult(conn.assigns.current_user)
    json(conn, %{adult_declared_at: user.adult_declared_at})
  end

  # ---------------------------------------------------------------------------
  # 入力検証（pydantic v2 の 422 の形を模す）
  # ---------------------------------------------------------------------------

  defp validate_signup(body) when is_map(body) do
    fields = [
      {"username", :required_string},
      {"email", :required_email},
      {"password", :required_string},
      {"account_type", :optional_string}
    ]

    case collect_errors(body, fields, body) do
      [] ->
        {:ok,
         %{
           "username" => body["username"],
           "email" => body["email"],
           "password" => body["password"],
           "account_type" => body["account_type"] || "author"
         }}

      errors ->
        {:error, errors}
    end
  end

  defp validate_signup(body),
    do: {:error, missing_errors(body, ["username", "email", "password"])}

  defp validate_login(body) when is_map(body) do
    fields = [{"username", :required_string}, {"password", :required_string}]

    # フォーム形式では、pydantic の missing エラーの input は null になる
    case collect_errors(body, fields, nil) do
      [] -> {:ok, %{"username" => body["username"], "password" => body["password"]}}
      errors -> {:error, errors}
    end
  end

  defp validate_login(body), do: {:error, missing_errors(body, ["username", "password"])}

  defp collect_errors(body, fields, missing_input) do
    Enum.flat_map(fields, fn
      {name, :required_string} ->
        required_string_error(body, name, missing_input)

      {name, :optional_string} ->
        optional_string_error(body, name)

      {name, :required_email} ->
        case required_string_error(body, name, missing_input) do
          [] ->
            if Accounts.valid_email?(body[name]),
              do: [],
              else: [email_error(body, name)]

          errors ->
            errors
        end
    end)
  end

  defp required_string_error(body, name, missing_input) do
    case Map.fetch(body, name) do
      :error ->
        [
          %{
            "type" => "missing",
            "loc" => ["body", name],
            "msg" => "Field required",
            "input" => missing_input
          }
        ]

      {:ok, value} when is_binary(value) ->
        []

      {:ok, value} ->
        [string_type_error(name, value)]
    end
  end

  defp optional_string_error(body, name) do
    case Map.fetch(body, name) do
      :error -> []
      {:ok, value} when is_binary(value) -> []
      {:ok, value} -> [string_type_error(name, value)]
    end
  end

  defp string_type_error(name, value) do
    %{
      "type" => "string_type",
      "loc" => ["body", name],
      "msg" => "Input should be a valid string",
      "input" => value
    }
  end

  defp email_error(body, name) do
    reason = email_reason(body[name])

    %{
      "type" => "value_error",
      "loc" => ["body", name],
      "msg" => "value is not a valid email address: #{reason}",
      "input" => body[name],
      "ctx" => %{"reason" => reason}
    }
  end

  # email-validator の理由文のうち、代表的なものだけを寄せる
  defp email_reason(email) do
    if String.contains?(email, "@") do
      "The email address is not valid."
    else
      "An email address must have an @-sign."
    end
  end

  defp missing_errors(input, names) do
    Enum.map(names, fn name ->
      %{
        "type" => "missing",
        "loc" => ["body", name],
        "msg" => "Field required",
        "input" => input
      }
    end)
  end

  defp form_content?(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _] ->
        String.starts_with?(content_type, "application/x-www-form-urlencoded") or
          String.starts_with?(content_type, "multipart/form-data")

      [] ->
        false
    end
  end
end
