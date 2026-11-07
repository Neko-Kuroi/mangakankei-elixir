defmodule PlatformExWeb.SessionController do
  @moduledoc """
  画面用のセッション操作（ログイン・登録・ログアウト・ビューワーURL設定）。
  ログインの確認順序と文言は API（AuthController）と揃え、
  成功したら API と同じ JWT をセッションに入れる。
  """
  use PlatformExWeb, :controller

  alias PlatformEx.{Accounts, Auth, LoginThrottle}
  alias PlatformExWeb.RateLimit

  @rate_message "リクエストが多すぎます。しばらく待ってから再試行してください。"

  # POST /session（ログイン）
  def create(conn, %{"username" => username, "password" => password}) do
    cond do
      not RateLimit.allowed?(conn, "login", 60_000, 5) ->
        back_to_login(conn, :error, @rate_message)

      LoginThrottle.blocked?(username) ->
        back_to_login(conn, :error, @rate_message)

      true ->
        case Accounts.authenticate(username, password) do
          {:ok, user} ->
            LoginThrottle.clear(username)

            conn
            |> put_session(:user_token, Auth.Token.issue(user.id))
            |> configure_session(renew: true)
            |> put_flash(:info, "#{user.username} としてログインしました")
            |> redirect(to: "/author")

          _ ->
            LoginThrottle.record_failure(username)
            back_to_login(conn, :error, "ユーザー名またはパスワードが正しくありません")
        end
    end
  end

  def create(conn, _params), do: back_to_login(conn, :error, "入力が不足しています")

  # POST /session/signup（登録）
  def signup(conn, params) do
    if not RateLimit.allowed?(conn, "signup", 3_600_000, 3) do
      back_to_login(conn, :error, @rate_message)
    else
      case Accounts.register_user(params) do
        {:ok, _user} ->
          back_to_login(conn, :info, "ユーザー登録が完了しました。ログインしてください。")

        {:error, message} when is_binary(message) ->
          back_to_login(conn, :error, message)
      end
    end
  end

  # POST /session/logout
  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "ログアウトしました")
    |> redirect(to: "/")
  end

  # POST /viewer-url（ビューワーURLの設定）
  def viewer_url(conn, %{"viewer_url" => url, "return_to" => return_to}) do
    conn
    |> put_session(:viewer_url, String.trim(url || ""))
    |> redirect(to: local_path(return_to))
  end

  def viewer_url(conn, _params), do: redirect(conn, to: "/")

  defp local_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    else
      "/"
    end
  end

  defp local_path(_), do: "/"

  defp back_to_login(conn, kind, message) do
    conn
    |> put_flash(kind, message)
    |> redirect(to: "/login")
  end
end
