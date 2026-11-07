defmodule PlatformExWeb.Plugs.RequireAuthor do
  @moduledoc """
  作者系エンドポイント用ガード（Python 版 get_current_author と同じ）。
  CurrentUser の後に使うこと。reader アカウントは 403。
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns.current_user.account_type == "reader" do
      conn
      |> put_status(403)
      |> Phoenix.Controller.json(%{detail: "読者アカウントでは利用できません"})
      |> halt()
    else
      conn
    end
  end
end
