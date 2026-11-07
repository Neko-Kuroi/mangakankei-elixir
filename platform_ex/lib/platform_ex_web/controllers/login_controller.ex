defmodule PlatformExWeb.LoginController do
  @moduledoc "アカウント画面（ログイン・新規登録フォーム）。送信先は SessionController。"
  use PlatformExWeb, :controller

  def show(conn, _params) do
    render(conn, :show,
      page_title: "アカウント",
      current_user: conn.assigns.current_user
    )
  end
end
