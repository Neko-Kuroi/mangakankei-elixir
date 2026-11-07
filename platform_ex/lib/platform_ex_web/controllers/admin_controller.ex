defmodule PlatformExWeb.AdminController do
  @moduledoc """
  管理者まわり（全作品一覧・公開停止・解除）と、作者の許可管理。
  URL・状態コード・文言は Python 版と揃える。
  """
  use PlatformExWeb, :controller

  alias PlatformEx.{Access, Works}

  plug PlatformExWeb.Plugs.CurrentUser
  plug PlatformExWeb.Plugs.RequireAuthor when action in [:grants, :create_grant, :delete_grant]
  plug PlatformExWeb.Plugs.RequireAdmin when action in [:works, :suspend, :resume]

  # ---------------------------------------------------------------------------
  # 許可（作者）
  # ---------------------------------------------------------------------------

  def grants(conn, %{"title_id" => tid_s}) do
    with {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         :ok <- author_title(conn, title_id) do
      json(conn, Access.list_grants(conn.assigns.current_user.id, title_id))
    else
      {:error, conn} -> conn
    end
  end

  def create_grant(conn, %{"title_id" => tid_s}) do
    with {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         :ok <- author_title(conn, title_id),
         {:ok, username} <- grant_username(conn) do
      case Access.create_grant(conn.assigns.current_user.id, title_id, username) do
        {:ok, result} -> json(conn, result)
        {:error, status, message} -> error(conn, status, message)
      end
    else
      {:error, conn} -> conn
    end
  end

  def delete_grant(conn, %{"title_id" => tid_s, "user_id" => uid_s}) do
    with {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, user_id} <- path_int(conn, "user_id", uid_s),
         :ok <- author_title(conn, title_id) do
      case Access.delete_grant(conn.assigns.current_user.id, title_id, user_id) do
        :ok -> json(conn, %{status: "success"})
        {:error, status, message} -> error(conn, status, message)
      end
    else
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # 管理者
  # ---------------------------------------------------------------------------

  def works(conn, _params) do
    json(conn, Works.admin_works())
  end

  def suspend(conn, %{"author_id" => aid_s, "title_id" => tid_s}) do
    with {:ok, author_id} <- path_int(conn, "author_id", aid_s),
         {:ok, title_id} <- path_int(conn, "title_id", tid_s),
         {:ok, reason} <- suspend_reason(conn),
         :ok <- title_exists(conn, author_id, title_id) do
      {:ok, result} = Access.suspend(conn.assigns.current_user, author_id, title_id, reason)
      json(conn, result)
    else
      {:error, conn} -> conn
    end
  end

  def resume(conn, %{"author_id" => aid_s, "title_id" => tid_s}) do
    with {:ok, author_id} <- path_int(conn, "author_id", aid_s),
         {:ok, title_id} <- path_int(conn, "title_id", tid_s) do
      case Access.resume(author_id, title_id) do
        {:ok, result} -> json(conn, result)
        {:error, status, message} -> error(conn, status, message)
      end
    else
      {:error, conn} -> conn
    end
  end

  # ---------------------------------------------------------------------------
  # 部品
  # ---------------------------------------------------------------------------

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{detail: message})
  end

  defp author_title(conn, title_id) do
    if Works.title_has_settings?(conn.assigns.current_user.id, title_id) do
      :ok
    else
      {:error, error(conn, 404, "作品が見つかりません")}
    end
  end

  defp title_exists(conn, author_id, title_id) do
    if Works.title_has_settings?(author_id, title_id) do
      :ok
    else
      {:error, error(conn, 404, "作品が見つかりません")}
    end
  end

  defp grant_username(conn) do
    body = conn.body_params

    cond do
      not is_map(body) or not Map.has_key?(body, "username") ->
        {:error, unprocessable(conn, body)}

      not is_binary(body["username"]) ->
        {:error,
         conn
         |> put_status(422)
         |> json(%{
           detail: [
             %{
               "type" => "string_type",
               "loc" => ["body", "username"],
               "msg" => "Input should be a valid string",
               "input" => body["username"]
             }
           ]
         })}

      true ->
        {:ok, body["username"]}
    end
  end

  defp suspend_reason(conn) do
    body = conn.body_params

    cond do
      not is_map(body) ->
        {:ok, ""}

      not Map.has_key?(body, "reason") ->
        {:ok, ""}

      is_binary(body["reason"]) ->
        {:ok, body["reason"]}

      true ->
        {:error,
         conn
         |> put_status(422)
         |> json(%{
           detail: [
             %{
               "type" => "string_type",
               "loc" => ["body", "reason"],
               "msg" => "Input should be a valid string",
               "input" => body["reason"]
             }
           ]
         })}
    end
  end

  defp unprocessable(conn, input) do
    conn
    |> put_status(422)
    |> json(%{
      detail: [
        %{
          "type" => "missing",
          "loc" => ["body", "username"],
          "msg" => "Field required",
          "input" => input
        }
      ]
    })
  end

  defp path_int(conn, name, value) do
    case Integer.parse(value) do
      {n, ""} ->
        {:ok, n}

      _ ->
        {:error,
         conn
         |> put_status(422)
         |> json(%{
           detail: [
             %{
               "type" => "int_parsing",
               "loc" => ["path", name],
               "msg" => "Input should be a valid integer, unable to parse string as an integer",
               "input" => value
             }
           ]
         })}
    end
  end
end
