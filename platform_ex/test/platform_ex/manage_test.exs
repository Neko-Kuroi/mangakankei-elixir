defmodule PlatformEx.ManageTest do
  use PlatformEx.DataCase, async: false

  alias PlatformEx.{Accounts, LegacySchema, Manage}

  setup do
    LegacySchema.setup!()
    old = System.get_env("MANGA_ADMIN_USERS")
    System.put_env("MANGA_ADMIN_USERS", "boss, chief")

    on_exit(fn ->
      case old do
        nil -> System.delete_env("MANGA_ADMIN_USERS")
        v -> System.put_env("MANGA_ADMIN_USERS", v)
      end
    end)

    :ok
  end

  test "create-admin：管理者名だけが作れ、内容が文言どおり返る" do
    assert {:error, msg} = Manage.create_admin("alice", "a@example.com", "password123")
    assert msg =~ "MANGA_ADMIN_USERS に含まれていません"

    assert {:error, "新規作成には --email が必要です"} =
             Manage.create_admin("boss", nil, "password123")

    assert {:error, "パスワードは8文字以上で入力してください"} =
             Manage.create_admin("boss", "boss@example.com", "short")

    assert {:ok, "管理者アカウントを作成しました: boss（email=boss@example.com, 種別=author）"} =
             Manage.create_admin("boss", "boss@example.com", "password123")

    # そのままログインでき、管理者として判定される
    assert {:ok, user} = Accounts.authenticate("boss", "password123")
    assert PlatformEx.Admin.admin?(user.username)

    # 既存（--reset なし）
    assert {:error, msg} = Manage.create_admin("boss", "boss@example.com", "password123")
    assert msg =~ "既に登録されています"

    # --reset で置き換え（有効化もされる）
    assert {:ok, "管理者アカウントを更新しました: boss（email=new@example.com, 種別=author）"} =
             Manage.create_admin("boss", "new@example.com", "newpassword9", reset: true)

    assert {:ok, _} = Accounts.authenticate("boss", "newpassword9")
  end

  test "list-admins：名前ごとに状況が返る" do
    {:ok, _} = Manage.create_admin("boss", "boss@example.com", "password123")
    lines = Manage.list_admins()
    assert Enum.any?(lines, &String.starts_with?(&1, "boss: 登録済み（id="))
    assert "chief: アカウントなし" in lines
  end
end
