defmodule PlatformEx.BootCheck do
  @moduledoc """
  起動時に管理者アカウントの状況をログに出す
  （Python 版の起動時ログと同じ文言・同じ扱い：
  アカウントなしは WARNING、登録済みは email つきで INFO、
  確認に失敗しても起動は妨げない。MANGA_ADMIN_USERS 未設定なら何もしない）。
  """
  require Logger

  alias PlatformEx.Admin

  def run do
    if Admin.names() != [] do
      try do
        for {name, status} <- Admin.status_report() do
          case status do
            :missing ->
              Logger.warning("管理者 #{name}: アカウントなし（manage.py create-admin で作成してください）")

            {:registered, email} ->
              Logger.info("管理者 #{name}: 登録済み（email=#{email}）")
          end
        end
      rescue
        e -> Logger.error("管理者アカウントの確認に失敗しました: #{Exception.message(e)}")
      end
    end

    :ok
  end
end
