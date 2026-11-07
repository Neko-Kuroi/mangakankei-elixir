defmodule PlatformExWeb.AuthControllerTest do
  use PlatformExWeb.ConnCase, async: false

  alias PlatformEx.{Accounts, LegacySchema}
  alias PlatformEx.Access.Grant
  alias PlatformEx.Repo

  @internal_token "test-internal-token"

  setup do
    LegacySchema.setup!()
    old = System.get_env("MANGA_ADMIN_USERS")
    System.put_env("MANGA_ADMIN_USERS", "conn_boss")

    on_exit(fn ->
      case old do
        nil -> System.delete_env("MANGA_ADMIN_USERS")
        v -> System.put_env("MANGA_ADMIN_USERS", v)
      end
    end)

    {:ok, key: fresh_key()}
  end

  defp fresh_key, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp uniq(prefix), do: "#{prefix}_#{:erlang.unique_integer([:positive])}"

  defp with_key(conn, key) do
    conn
    |> put_req_header("x-internal-token", @internal_token)
    |> put_req_header("x-viewer-client-key", key)
  end

  defp signup(conn, key, attrs) do
    conn
    |> with_key(key)
    |> put_req_header("content-type", "application/json")
    |> post("/api/auth/signup", Jason.encode!(attrs))
  end

  defp login(conn, key, username, password) do
    conn
    |> with_key(key)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/api/auth/token", %{"username" => username, "password" => password})
  end

  defp valid_attrs(name) do
    %{
      "username" => name,
      "email" => "#{name}@example.com",
      "password" => "password123",
      "account_type" => "reader"
    }
  end

  test "登録→ログイン→me の一連が Python 版の形で返る", %{key: key} do
    name = uniq("flow")

    conn = signup(build_conn(), key, valid_attrs(name))
    assert json_response(conn, 200) == %{"message" => "ユーザー登録が完了しました。ログインしてください。"}

    conn = login(build_conn(), key, name, "password123")
    body = json_response(conn, 200)
    assert body["token_type"] == "bearer"
    assert body["username"] == name
    token = body["access_token"]
    assert is_binary(token) and token != ""

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/auth/me")

    me = json_response(conn, 200)
    assert me["username"] == name
    assert me["email"] == "#{name}@example.com"
    assert me["account_type"] == "reader"
    assert me["is_admin"] == false
    assert me["adult_declared_at"] == nil
  end

  test "登録の 400 系：メール重複・予約名（表記ゆれ）・短いパスワード", %{key: key} do
    name = uniq("dup")
    conn = signup(build_conn(), key, valid_attrs(name))
    assert json_response(conn, 200)

    # メール重複
    conn =
      signup(build_conn(), fresh_key(), %{
        "username" => uniq("other"),
        "email" => "#{name}@example.com",
        "password" => "password123"
      })

    assert json_response(conn, 400) == %{"detail" => "登録済みのメールアドレスです"}

    # 予約名（管理者名 conn_boss の表記ゆれ）
    conn = signup(build_conn(), fresh_key(), valid_attrs("CONN_BOSS"))
    assert json_response(conn, 400) == %{"detail" => "使用済みのユーザー名です"}

    # 短いパスワード
    conn =
      signup(build_conn(), fresh_key(), %{
        "username" => uniq("short"),
        "email" => "#{uniq("s")}@example.com",
        "password" => "short"
      })

    assert json_response(conn, 400) == %{"detail" => "パスワードは8文字以上で入力してください"}
  end

  test "登録の 422：必須欠けとメール形式（pydantic の形）", %{key: key} do
    conn =
      signup(build_conn(), key, %{"username" => uniq("v"), "email" => "v@example.com"})

    body = json_response(conn, 422)
    [error] = body["detail"]
    assert error["type"] == "missing"
    assert error["loc"] == ["body", "password"]
    assert error["msg"] == "Field required"

    conn =
      signup(build_conn(), fresh_key(), valid_attrs(uniq("w")) |> Map.put("email", "notanemail"))

    body = json_response(conn, 422)
    [error] = body["detail"]
    assert error["type"] == "value_error"
    assert String.starts_with?(error["msg"], "value is not a valid email address: ")
  end

  test "ログイン失敗は 401、ユーザー名カウンタでブロックされると 429（JSON）" do
    name = uniq("block")
    {:ok, _} = Accounts.register_user(valid_attrs(name))

    # クライアントキーを毎回変えても、ユーザー名カウンタは効く
    for _ <- 1..5 do
      conn = login(build_conn(), fresh_key(), name, "wrong-password")
      assert json_response(conn, 401) == %{"detail" => "ユーザー名またはパスワードが正しくありません"}
    end

    conn = login(build_conn(), fresh_key(), name, "password123")

    assert json_response(conn, 429) == %{
             "detail" => "リクエストが多すぎます。しばらく待ってから再試行してください。"
           }
  end

  test "ログインの送信元枠：同じキーで6回目は 429（テキスト）" do
    key = fresh_key()
    name = uniq("iplimit")
    {:ok, _} = Accounts.register_user(valid_attrs(name))

    for i <- 1..5 do
      conn = login(build_conn(), key, "#{name}_#{i}", "wrong-password")
      assert json_response(conn, 401)
    end

    conn = login(build_conn(), key, "#{name}_6", "wrong-password")
    assert response(conn, 429) == "リクエストが多すぎます。しばらく待ってから再試行してください。"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
  end

  test "登録の送信元枠：同じキーで4件目は 429、キーが違えば通る" do
    key = fresh_key()

    for i <- 1..3 do
      conn = signup(build_conn(), key, valid_attrs(uniq("rl#{i}")))
      assert json_response(conn, 200)
    end

    conn = signup(build_conn(), key, valid_attrs(uniq("rl4")))
    assert response(conn, 429) == "リクエストが多すぎます。しばらく待ってから再試行してください。"

    conn = signup(build_conn(), fresh_key(), valid_attrs(uniq("rl5")))
    assert json_response(conn, 200)
  end

  test "me の認証失敗：ヘッダなしと壊れたトークンで文言が違う" do
    conn = get(build_conn(), "/api/auth/me")
    assert json_response(conn, 401) == %{"detail" => "Not authenticated"}

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer garbage")
      |> get("/api/auth/me")

    assert json_response(conn, 401) == %{"detail" => "トークンが無効または期限切れです"}
  end

  test "年齢申告は冪等で、me に反映される", %{key: key} do
    name = uniq("adult")
    {:ok, user} = Accounts.register_user(valid_attrs(name))
    token = PlatformEx.Auth.Token.issue(user.id)
    auth = fn -> put_req_header(build_conn(), "authorization", "Bearer #{token}") end

    conn = post(auth.(), "/api/auth/declare-adult")
    first = json_response(conn, 200)["adult_declared_at"]
    assert is_binary(first)

    conn = post(auth.(), "/api/auth/declare-adult")
    assert json_response(conn, 200)["adult_declared_at"] == first

    conn = get(auth.(), "/api/auth/me")
    assert json_response(conn, 200)["adult_declared_at"] == first

    _ = key
  end

  test "grants は自分の許可だけを返す", %{key: _key} do
    name = uniq("grants")
    {:ok, user} = Accounts.register_user(valid_attrs(name))
    %Grant{author_id: 7, title_id: 42, user_id: user.id} |> Repo.insert!()
    %Grant{author_id: 8, title_id: 43, user_id: user.id + 999} |> Repo.insert!()

    conn =
      build_conn()
      |> put_req_header(
        "authorization",
        "Bearer #{PlatformEx.Auth.Token.issue(user.id)}"
      )
      |> get("/api/auth/grants")

    assert json_response(conn, 200) == [%{"author_id" => 7, "title_id" => 42}]
  end
end
