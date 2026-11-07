defmodule PlatformEx.AccessTest do
  use PlatformEx.DataCase, async: false

  alias PlatformEx.{Access, Accounts, LegacySchema}
  alias PlatformEx.Accounts.User

  setup do
    LegacySchema.setup!()
    :ok
  end

  defp register(name, type \\ "author") do
    {:ok, user} =
      Accounts.register_user(%{
        "username" => name,
        "email" => "#{name}@example.com",
        "password" => "password123",
        "account_type" => type
      })

    user
  end

  test "許可の作成・冪等・一覧・削除" do
    author = register("author1")
    reader = register("reader1", "reader")

    assert {:ok, %{already: false, user_id: uid}} =
             Access.create_grant(author.id, 501, "reader1")

    assert uid == reader.id
    assert {:ok, %{already: true}} = Access.create_grant(author.id, 501, "reader1")
    assert Access.has_grant?(author.id, 501, reader.id)
    refute Access.has_grant?(author.id, 502, reader.id)

    assert [%{user_id: uid2, username: "reader1", created_at: %NaiveDateTime{}}] =
             Access.list_grants(author.id, 501)

    assert uid2 == reader.id

    assert {:error, 400, "自分自身には許可できません"} =
             Access.create_grant(author.id, 501, "author1")

    assert {:error, 404, "ユーザーが見つかりません"} =
             Access.create_grant(author.id, 501, "ghost")

    assert {:error, 404, "許可が見つかりません"} =
             Access.delete_grant(author.id, 501, 999)

    assert :ok = Access.delete_grant(author.id, 501, reader.id)
    refute Access.has_grant?(author.id, 501, reader.id)
  end

  test "公開停止と解除" do
    admin = register("boss")

    assert {:ok, %{status: "suspended", reason: "規約違反"}} =
             Access.suspend(admin, 1, 501, "規約違反")

    assert %Access.Suspension{} = Access.active_suspension(1, 501)

    assert {:error, 403, "この作品は公開が停止されています"} =
             Access.enforce_not_suspended(1, 501)

    assert {:ok, %{status: "already_suspended", reason: "規約違反"}} =
             Access.suspend(admin, 1, 501, "別の理由")

    assert {:ok, %{status: "resumed"}} = Access.resume(1, 501)
    assert Access.active_suspension(1, 501) == nil
    assert :ok = Access.enforce_not_suspended(1, 501)
    assert {:error, 404, "公開停止されていません"} = Access.resume(1, 501)
  end

  test "enforce_premium の判定表" do
    author = register("author1")
    reader = register("reader1", "reader")
    public = %{"access_level" => "public"}
    premium = %{"access_level" => "premium"}
    premium_age = %{"access_level" => "premium", "age_restricted" => true}

    assert :ok = Access.enforce_premium(public, author.id, 501, nil)

    assert {:error, 401, "この作品を読むにはログインが必要です"} =
             Access.enforce_premium(premium, author.id, 501, nil)

    # 作者本人は素通り
    assert :ok = Access.enforce_premium(premium, author.id, 501, author)

    # 許可が無ければ 403
    assert {:error, 403, "この作品を読む許可がありません"} =
             Access.enforce_premium(premium, author.id, 501, reader)

    {:ok, _} = Access.create_grant(author.id, 501, "reader1")
    assert :ok = Access.enforce_premium(premium, author.id, 501, reader)

    # 年齢対象は申告が要る
    assert {:error, 403, "この作品を読むには年齢確認が必要です"} =
             Access.enforce_premium(premium_age, author.id, 501, reader)

    declared_reader = %User{reader | adult_declared_at: ~N[2026-01-01 00:00:00]}
    assert :ok = Access.enforce_premium(premium_age, author.id, 501, declared_reader)
  end

  test "enforce_age の判定表" do
    author = register("author1")
    reader = register("reader1", "reader")
    plain = %{"access_level" => "public"}
    aged = %{"access_level" => "public", "age_restricted" => true}
    premium_aged = %{"access_level" => "premium", "age_restricted" => true}

    assert :ok = Access.enforce_age(plain, author.id, nil, false)
    # premium の年齢は enforce_premium 側の担当
    assert :ok = Access.enforce_age(premium_aged, author.id, nil, false)

    assert {:error, 403, "年齢確認が必要です"} = Access.enforce_age(aged, author.id, nil, false)

    assert {:error, 403, "年齢確認が必要です"} =
             Access.enforce_age(aged, author.id, reader, false)

    assert :ok = Access.enforce_age(aged, author.id, author, false)

    declared_reader = %User{reader | adult_declared_at: ~N[2026-01-01 00:00:00]}
    assert :ok = Access.enforce_age(aged, author.id, declared_reader, false)
    # 内部通信＋年齢確認済みヘッダ
    assert :ok = Access.enforce_age(aged, author.id, nil, true)
  end
end
