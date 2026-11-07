defmodule PlatformExWeb.Plugs.RequireAdmin do
  @moduledoc """
  管理者用ガード（Python 版 get_current_admin と同じ）。
  CurrentUser の後に使うこと。管理者でなければ 403。
  """
  import Plug.Conn

  alias PlatformEx.Admin

  def init(opts), do: opts

  def call(conn, _opts) do
    if Admin.admin?(conn.assigns.current_user.username) do
      conn
    else
      conn
      |> put_status(403)
      |> Phoenix.Controller.json(%{detail: "管理者権限が必要です"})
      |> halt()
    end
  end
end
