defmodule PlatformExWeb.AdminControllerTest do
  use PlatformExWeb.ConnCase, async: false

  alias PlatformEx.{Accounts, LegacySchema, Storage, Works}

  setup do
    LegacySchema.setup!()

    root =
      Path.join(System.tmp_dir!(), "admin_ctrl_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old_storage = Application.get_env(:platform_ex, :storage_dir)
    Application.put_env(:platform_ex, :storage_dir, root)
    old_admins = System.get_env("MANGA_ADMIN_USERS")

    {:ok, boss} = register("boss4", "author")
    {:ok, author} = register("ad_author", "author")
    {:ok, reader} = register("ad_reader", "reader")
    System.put_env("MANGA_ADMIN_USERS", "boss4")

    on_exit(fn ->
      if old_storage,
        do: Application.put_env(:platform_ex, :storage_dir, old_storage),
        else: Application.delete_env(:platform_ex, :storage_dir)

      if old_admins,
        do: System.put_env("MANGA_ADMIN_USERS", old_admins),
        else: System.delete_env("MANGA_ADMIN_USERS")

      File.rm_rf!(root)
    end)

    make_work(author, 21, "published")
    make_work(author, 22, "draft")

    {:ok,
     boss_token: PlatformEx.Auth.Token.issue(boss.id),
     author: author,
     author_token: PlatformEx.Auth.Token.issue(author.id),
     reader_token: PlatformEx.Auth.Token.issue(reader.id)}
  end

  defp register(name, type) do
    Accounts.register_user(%{
      "username" => name,
      "email" => "#{name}@example.com",
      "password" => "password123",
      "account_type" => type
    })
  end

  defp make_work(author, title_id, status) do
    File.mkdir_p!(Storage.title_dir(author.id, title_id))
    File.write!(Storage.cbz_path(author.id, title_id, 1), "CBZ-#{title_id}")

    settings = %{
      "status" => status,
      "access_level" => "public",
      "title_name" => "作品#{title_id}",
      "episode_name" => "第1話",
      "caption" => "",
      "comment" => "",
      "note" => "秘密の備考",
      "scrambled" => true,
      "tile_size" => 16,
      "webhook_enabled" => false,
      "age_restricted" => false
    }

    :ok = Works.update_settings(author, title_id, 1, settings)
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "許可の管理（一覧・追加・冪等・自分 400・不在 404・削除）", %{
    author_token: at,
    reader_token: rt
  } do
    conn = build_conn() |> bearer(at) |> get("/api/author/titles/21/grants")
    assert json_response(conn, 200) == []

    conn =
      build_conn()
      |> bearer(at)
      |> json_post("/api/author/titles/21/grants", %{"username" => "ad_reader"})

    body = json_response(conn, 200)
    assert body["username"] == "ad_reader"
    assert body["already"] == false

    conn =
      build_conn()
      |> bearer(at)
      |> json_post("/api/author/titles/21/grants", %{"username" => "ad_reader"})

    assert json_response(conn, 200)["already"] == true

    conn = build_conn() |> bearer(at) |> get("/api/author/titles/21/grants")
    [grant] = json_response(conn, 200)
    assert grant["username"] == "ad_reader"
    assert is_binary(grant["created_at"])

    conn =
      build_conn()
      |> bearer(at)
      |> json_post("/api/author/titles/21/grants", %{"username" => "ad_author"})

    assert json_response(conn, 400) == %{"detail" => "自分自身には許可できません"}

    conn =
      build_conn()
      |> bearer(at)
      |> json_post("/api/author/titles/21/grants", %{"username" => "ghost"})

    assert json_response(conn, 404) == %{"detail" => "ユーザーが見つかりません"}

    conn = build_conn() |> bearer(at) |> json_post("/api/author/titles/21/grants", %{})
    assert json_response(conn, 422)

    conn =
      build_conn()
      |> bearer(at)
      |> json_post("/api/author/titles/99/grants", %{"username" => "ad_reader"})

    assert json_response(conn, 404) == %{"detail" => "作品が見つかりません"}

    conn = build_conn() |> bearer(rt) |> get("/api/author/titles/21/grants")
    assert json_response(conn, 403) == %{"detail" => "読者アカウントでは利用できません"}

    conn =
      build_conn() |> bearer(at) |> delete("/api/author/titles/21/grants/#{grant["user_id"]}")

    assert json_response(conn, 200) == %{"status" => "success"}

    conn =
      build_conn() |> bearer(at) |> delete("/api/author/titles/21/grants/#{grant["user_id"]}")

    assert json_response(conn, 404) == %{"detail" => "許可が見つかりません"}
  end

  test "管理者：全作品一覧（note 除外）・停止・解除", %{
    boss_token: bt,
    author: author,
    author_token: at
  } do
    conn = build_conn() |> bearer(at) |> get("/api/admin/works")
    assert json_response(conn, 403) == %{"detail" => "管理者権限が必要です"}

    conn = build_conn() |> bearer(bt) |> get("/api/admin/works")
    works = json_response(conn, 200)
    assert Enum.map(works, & &1["title_id"]) |> Enum.sort() == [21, 22]
    assert Enum.all?(works, &(not Map.has_key?(&1, "note")))
    assert Enum.all?(works, &(&1["suspended"] == false))

    conn =
      build_conn()
      |> bearer(bt)
      |> json_post("/api/admin/titles/#{author.id}/21/suspend", %{"reason" => "テスト停止"})

    assert json_response(conn, 200) == %{"status" => "suspended", "reason" => "テスト停止"}

    conn =
      build_conn()
      |> bearer(bt)
      |> json_post("/api/admin/titles/#{author.id}/21/suspend", %{"reason" => "別の理由"})

    assert json_response(conn, 200) == %{"status" => "already_suspended", "reason" => "テスト停止"}

    # 停止中は公開 CBZ も 403
    conn =
      build_conn()
      |> put_req_header("x-internal-token", "test-internal-token")
      |> get("/api/public/cbz/#{author.id}/21/1.cbz")

    assert json_response(conn, 403) == %{"detail" => "この作品は公開が停止されています"}

    conn = build_conn() |> bearer(bt) |> get("/api/admin/works")
    [w21] = Enum.filter(json_response(conn, 200), &(&1["title_id"] == 21))
    assert w21["suspended"] == true
    assert w21["suspend_reason"] == "テスト停止"

    conn = build_conn() |> bearer(bt) |> post("/api/admin/titles/#{author.id}/21/resume", %{})
    assert json_response(conn, 200) == %{"status" => "resumed"}

    conn = build_conn() |> bearer(bt) |> post("/api/admin/titles/#{author.id}/21/resume", %{})
    assert json_response(conn, 404) == %{"detail" => "公開停止されていません"}

    conn =
      build_conn()
      |> bearer(bt)
      |> json_post("/api/admin/titles/#{author.id}/99/suspend", %{})

    assert json_response(conn, 404) == %{"detail" => "作品が見つかりません"}
  end
end
