defmodule PlatformExWeb.Plugs.CurrentUser do
  @moduledoc """
  Authorization: Bearer <JWT> から現在のユーザーを引いて
  conn.assigns.current_user に置く。失敗時の文言は Python 版に揃える：

  - ヘッダなし・Bearer でない → 401 "Not authenticated"（FastAPI の OAuth2 の既定）
  - トークンが無効・期限切れ → 401 「トークンが無効または期限切れです」
  - ユーザー不在・停止中 → 401 「ユーザーが見つかりません」
  """
  import Plug.Conn

  alias PlatformEx.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer_token(conn) do
      nil ->
        unauthorized(conn, "Not authenticated")

      token ->
        case Accounts.user_from_token(token) do
          {:ok, user} -> assign(conn, :current_user, user)
          {:error, message} -> unauthorized(conn, message)
        end
    end
  end

  defp bearer_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         true <- token != "" do
      token
    else
      _ -> nil
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{detail: message})
    |> halt()
  end
end
