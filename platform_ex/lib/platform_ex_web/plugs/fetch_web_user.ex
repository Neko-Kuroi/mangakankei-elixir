defmodule PlatformExWeb.Plugs.FetchWebUser do
  @moduledoc """
  画面共通の assign を用意する（レイアウトのナビ用）。
  セッションの JWT からユーザーと、管理者判定・ビューワーURLを引く。
  LiveView 側は on_mount が同じ assign をするので、これは通常レンダリング用。
  """
  import Plug.Conn

  alias PlatformEx.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    user =
      case get_session(conn, :user_token) do
        token when is_binary(token) ->
          case Accounts.user_from_token(token) do
            {:ok, user} -> user
            _ -> nil
          end

        _ ->
          nil
      end

    conn
    |> assign(:current_user, user)
    |> assign(:viewer_url, get_session(conn, :viewer_url) || "")
  end
end
