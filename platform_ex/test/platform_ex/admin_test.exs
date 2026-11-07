defmodule PlatformEx.AdminTest do
  use ExUnit.Case, async: false

  alias PlatformEx.Admin

  setup do
    old = System.get_env("MANGA_ADMIN_USERS")
    System.delete_env("MANGA_ADMIN_USERS")

    on_exit(fn ->
      case old do
        nil -> System.delete_env("MANGA_ADMIN_USERS")
        v -> System.put_env("MANGA_ADMIN_USERS", v)
      end
    end)

    :ok
  end

  test "未設定なら管理者はいない" do
    assert Admin.names() == []
    refute Admin.admin?("anyone")
  end

  test "カンマ区切りで読み、前後空白・空要素・重複を取り除く" do
    System.put_env("MANGA_ADMIN_USERS", " alice , bob,,alice ,")
    assert Admin.names() == ["alice", "bob"]
  end

  test "admin? は完全一致（大文字小文字の違いは別人）" do
    System.put_env("MANGA_ADMIN_USERS", "Alice")
    assert Admin.admin?("Alice")
    refute Admin.admin?("alice")
  end
end
