defmodule PlatformEx.AccountsTest do
  use PlatformEx.DataCase, async: false

  alias PlatformEx.{Accounts, LegacySchema}
  alias PlatformEx.Access.Grant

  setup do
    LegacySchema.setup!()
    old = System.get_env("MANGA_ADMIN_USERS")

    on_exit(fn ->
      case old do
        nil -> System.delete_env("MANGA_ADMIN_USERS")
        v -> System.put_env("MANGA_ADMIN_USERS", v)
      end
    end)

    :ok
  end

  defp uniq(prefix), do: "#{prefix}_#{:erlang.unique_integer([:positive])}"

  defp register!(username, opts \\ []) do
    {:ok, user} =
      Accounts.register_user(%{
        "username" => username,
        "email" => Keyword.get(opts, :email, "#{username}@example.com"),
        "password" => Keyword.get(opts, :password, "password123"),
        "account_type" => Keyword.get(opts, :account_type, "author")
      })

    user
  end

  describe "normalize_username/1" do
    test "NFKC・大文字小文字・前後空白・ゼロ幅文字を寄せる" do
      assert Accounts.normalize_username(" Ａｌｉｃｅ ") == "alice"
      assert Accounts.normalize_username("Al​ice") == "alice"
      assert Accounts.normalize_username("ALICE") == "alice"
      assert Accounts.normalize_username("Straße") == "strasse"
    end

    test "文字そのものが違う名前は寄せない" do
      assert Accounts.normalize_username("alice2") != Accounts.normalize_username("alice")
      assert Accounts.normalize_username("al ice") != Accounts.normalize_username("alice")
    end
  end

  describe "reserved_username?/1" do
    test "管理者名と、その表記ゆれだけが予約される" do
      System.put_env("MANGA_ADMIN_USERS", "Boss")
      assert Accounts.reserved_username?("boss")
      assert Accounts.reserved_username?("ＢＯＳＳ")
      assert Accounts.reserved_username?("Bo​ss")
      refute Accounts.reserved_username?("bossy")
      refute Accounts.reserved_username?("alice")
    end

    test "管理者が未設定なら何も予約されない" do
      System.delete_env("MANGA_ADMIN_USERS")
      refute Accounts.reserved_username?("boss")
    end
  end

  describe "password_rule_error/1" do
    test "8文字未満は不可、72バイト超は不可（バイト数は文字数ではなくバイト）" do
      assert Accounts.password_rule_error("1234567") ==
               "パスワードは8文字以上で入力してください"

      assert Accounts.password_rule_error("12345678") == nil
      # 日本語9文字=27バイトは範囲内、日本語25文字=75バイトは超過
      assert Accounts.password_rule_error(String.duplicate("あ", 9)) == nil

      assert Accounts.password_rule_error(String.duplicate("あ", 25)) ==
               "パスワードが長すぎます（72バイトまで）"
    end
  end

  describe "register_user/1" do
    test "正常に登録でき、パスワードは検証できる" do
      user = register!(uniq("reg"))
      assert user.account_type == "author"
      assert Accounts.verify_password("password123", user.hashed_password)
      refute Accounts.verify_password("password999", user.hashed_password)
    end

    test "チェックの順序：メール重複が最初、次に予約名、次に名前重複" do
      System.put_env("MANGA_ADMIN_USERS", "reservedname")
      existing = register!(uniq("dup"))

      # メール重複（予約名でもある名前でも、メール重複が先に出る）
      assert {:error, "登録済みのメールアドレスです"} =
               Accounts.register_user(%{
                 "username" => "reservedname",
                 "email" => existing.email,
                 "password" => "password123",
                 "account_type" => "author"
               })

      # 予約名
      assert {:error, "使用済みのユーザー名です"} =
               Accounts.register_user(%{
                 "username" => "ReservedName",
                 "email" => "new-#{uniq("e")}@example.com",
                 "password" => "password123",
                 "account_type" => "author"
               })

      # 名前重複
      assert {:error, "使用済みのユーザー名です"} =
               Accounts.register_user(%{
                 "username" => existing.username,
                 "email" => "new-#{uniq("e")}@example.com",
                 "password" => "password123",
                 "account_type" => "author"
               })
    end

    test "種別不正とパスワード規則" do
      assert {:error, "アカウント種別が不正です"} =
               Accounts.register_user(%{
                 "username" => uniq("t"),
                 "email" => "#{uniq("e")}@example.com",
                 "password" => "password123",
                 "account_type" => "admin"
               })

      assert {:error, "パスワードは8文字以上で入力してください"} =
               Accounts.register_user(%{
                 "username" => uniq("t"),
                 "email" => "#{uniq("e")}@example.com",
                 "password" => "short",
                 "account_type" => "reader"
               })
    end
  end

  describe "authenticate/2" do
    test "正しい資格情報で成功し、間違いは 401" do
      user = register!(uniq("auth"))
      assert {:ok, ^user} = Accounts.authenticate(user.username, "password123")

      assert {:error, 401, "ユーザー名またはパスワードが正しくありません"} =
               Accounts.authenticate(user.username, "wrong-password")

      assert {:error, 401, _} = Accounts.authenticate(uniq("ghost"), "password123")
    end

    test "失敗5回でブロックされ、正しいパスワードでも 429。成功すると数え直し" do
      user = register!(uniq("throttle"))

      for _ <- 1..4 do
        assert {:error, 401, _} = Accounts.authenticate(user.username, "wrong-password")
      end

      # 4回までは成功できる（成功でリセット）
      assert {:ok, _} = Accounts.authenticate(user.username, "password123")

      for _ <- 1..5 do
        assert {:error, 401, _} = Accounts.authenticate(user.username, "wrong-password")
      end

      assert {:error, 429, "リクエストが多すぎます。しばらく待ってから再試行してください。"} =
               Accounts.authenticate(user.username, "password123")
    end

    test "停止中アカウントは正しいパスワードでも 401 で、失敗として数える" do
      user = register!(uniq("inactive"))
      {:ok, _} = user |> Ecto.Changeset.change(is_active: false) |> Repo.update()

      assert {:error, 401, "ユーザー名またはパスワードが正しくありません"} =
               Accounts.authenticate(user.username, "password123")
    end
  end

  describe "user_from_token/1 と declare_adult/1 と grants_for_user/1" do
    test "トークンでユーザーを引き、年齢申告は冪等、許可一覧が返る" do
      user = register!(uniq("tok"))
      token = PlatformEx.Auth.Token.issue(user.id)
      assert {:ok, loaded} = Accounts.user_from_token(token)
      assert loaded.id == user.id

      assert {:error, "トークンが無効または期限切れです"} =
               Accounts.user_from_token("garbage.token.here")

      assert loaded.adult_declared_at == nil
      {:ok, declared} = Accounts.declare_adult(loaded)
      assert declared.adult_declared_at != nil
      {:ok, again} = Accounts.declare_adult(declared)
      assert again.adult_declared_at == declared.adult_declared_at

      %Grant{author_id: 7, title_id: 42, user_id: user.id} |> Repo.insert!()
      assert Accounts.grants_for_user(user) == [%{author_id: 7, title_id: 42}]
    end

    test "停止中ユーザーのトークンは「ユーザーが見つかりません」" do
      user = register!(uniq("tokstop"))
      token = PlatformEx.Auth.Token.issue(user.id)
      {:ok, _} = user |> Ecto.Changeset.change(is_active: false) |> Repo.update()
      assert {:error, "ユーザーが見つかりません"} = Accounts.user_from_token(token)
    end
  end
end
