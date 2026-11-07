defmodule PlatformExWeb.PublicControllerTest do
  use PlatformExWeb.ConnCase, async: false

  alias PlatformEx.{Accounts, Access, LegacySchema, Storage, Works}

  @internal %{"x-internal-token" => "test-internal-token"}

  setup do
    LegacySchema.setup!()

    root =
      Path.join(System.tmp_dir!(), "public_ctrl_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old = Application.get_env(:platform_ex, :storage_dir)
    Application.put_env(:platform_ex, :storage_dir, root)

    on_exit(fn ->
      if old,
        do: Application.put_env(:platform_ex, :storage_dir, old),
        else: Application.delete_env(:platform_ex, :storage_dir)

      File.rm_rf!(root)
    end)

    {:ok, author} = register("pub_author", "author")
    {:ok, reader} = register("pub_reader", "reader")
    {:ok, reader2} = register("pub_reader2", "reader")

    # T11: 公開・無料 / T12: 公開・許可制 / T13: 公開・無料・年齢 / T14: 下書き
    make_work(author, 11, "public", [])
    make_work(author, 12, "premium", [])
    make_work(author, 13, "public", age_restricted: true)
    make_work(author, 14, "public", status: "draft")
    {:ok, _} = Access.create_grant(author.id, 12, "pub_reader")

    {:ok,
     root: root,
     author: author,
     reader: reader,
     reader2: reader2,
     author_token: PlatformEx.Auth.Token.issue(author.id),
     reader_token: PlatformEx.Auth.Token.issue(reader.id),
     reader2_token: PlatformEx.Auth.Token.issue(reader2.id)}
  end

  defp register(name, type) do
    Accounts.register_user(%{
      "username" => name,
      "email" => "#{name}@example.com",
      "password" => "password123",
      "account_type" => type
    })
  end

  defp make_work(author, title_id, access_level, opts) do
    File.mkdir_p!(Storage.title_dir(author.id, title_id))
    File.write!(Storage.cbz_path(author.id, title_id, 1), "CBZ-#{title_id}")
    File.write!(Storage.cover_path(author.id, title_id, 1), "COVER-#{title_id}")
    File.mkdir_p!(Storage.thumbs_dir(author.id, title_id, 1))
    File.write!(Storage.thumb_path(author.id, title_id, 1, 0), "THUMB-#{title_id}-0")
    File.write!(Storage.thumb_path(author.id, title_id, 1, 1), "THUMB-#{title_id}-1")

    settings = %{
      "status" => Keyword.get(opts, :status, "published"),
      "access_level" => access_level,
      "title_name" => "作品#{title_id}",
      "episode_name" => "第1話",
      "caption" => "",
      "comment" => "",
      "note" => "備考#{title_id}",
      "scrambled" => true,
      "tile_size" => 16,
      "webhook_enabled" => false,
      "age_restricted" => Keyword.get(opts, :age_restricted, false)
    }

    :ok = Works.update_settings(author, title_id, 1, settings)
  end

  defp internal(conn) do
    Enum.reduce(@internal, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  test "カタログ：公開のみ・年齢は cover_url が null・note は出ない", %{author: author} do
    conn = build_conn() |> internal() |> get("/api/public/catalog")
    works = json_response(conn, 200)

    by_title = Map.new(works, &{&1["title_id"], &1})
    assert Map.keys(by_title) |> Enum.sort() == [11, 12, 13]
    assert by_title[11]["cbz_url"] =~ "/api/public/cbz/#{author.id}/11/1.cbz"
    assert by_title[11]["cover_url"] =~ "/api/public/cover/#{author.id}/11/1"
    assert by_title[13]["cover_url"] == nil
    refute Map.has_key?(by_title[11], "note")
  end

  test "CBZ：無料は匿名で読め、閲覧数が1だけ増える（クールダウン）", %{author: author} do
    url = "/api/public/cbz/#{author.id}/11/1.cbz"

    conn = build_conn() |> internal() |> get(url)
    assert conn.status == 200
    assert conn.resp_body == "CBZ-11"

    assert get_resp_header(conn, "content-disposition") |> hd() =~
             ~s(filename="title11_ep1.cbz")

    assert get_resp_header(conn, "cache-control") |> hd() == "public, max-age=3600"

    settings = Storage.settings_path(author.id, 11, 1) |> File.read!() |> Jason.decode!()
    assert settings["view_count"] == 1

    conn = build_conn() |> internal() |> get(url)
    assert conn.status == 200
    settings = Storage.settings_path(author.id, 11, 1) |> File.read!() |> Jason.decode!()
    assert settings["view_count"] == 1
  end

  test "CBZ：許可制の執行（匿名401・無許可403・許可済み200・作者200）", %{
    author: author,
    author_token: at,
    reader_token: rt,
    reader2_token: r2t
  } do
    url = "/api/public/cbz/#{author.id}/12/1.cbz"

    conn = build_conn() |> internal() |> get(url)
    assert json_response(conn, 401) == %{"detail" => "この作品を読むにはログインが必要です"}

    conn = build_conn() |> bearer(r2t) |> get(url)
    assert json_response(conn, 403) == %{"detail" => "この作品を読む許可がありません"}

    conn = build_conn() |> bearer(rt) |> get(url)
    assert conn.status == 200

    conn = build_conn() |> bearer(at) |> get(url)
    assert conn.status == 200

    # Authorization があるのに Bearer でない → 401
    conn = build_conn() |> put_req_header("authorization", "Token xyz") |> get(url)
    assert json_response(conn, 401) == %{"detail" => "トークンが無効または期限切れです"}

    # 壊れた Bearer トークン → 401
    conn = build_conn() |> bearer("garbage.token.here") |> get(url)
    assert json_response(conn, 401) == %{"detail" => "トークンが無効または期限切れです"}
  end

  test "CBZ：年齢対象の執行（匿名403・内部の年齢確認200・申告済み200）", %{
    author: author,
    reader2: reader2,
    reader2_token: r2t
  } do
    url = "/api/public/cbz/#{author.id}/13/1.cbz"

    conn = build_conn() |> internal() |> get(url)
    assert json_response(conn, 403) == %{"detail" => "年齢確認が必要です"}

    conn =
      build_conn()
      |> internal()
      |> put_req_header("x-age-verified", "1")
      |> get(url)

    assert conn.status == 200

    {:ok, _} = Accounts.declare_adult(reader2)
    conn = build_conn() |> bearer(r2t) |> get(url)
    assert conn.status == 200
  end

  test "CBZ：下書き403・設定なし404・CBZ 実体なし404", %{author: author} do
    conn = build_conn() |> internal() |> get("/api/public/cbz/#{author.id}/14/1.cbz")
    assert json_response(conn, 403) == %{"detail" => "この作品は非公開です"}

    conn = build_conn() |> internal() |> get("/api/public/cbz/#{author.id}/99/1.cbz")
    assert json_response(conn, 404) == %{"detail" => "作品が見つかりません"}

    # 設定だけあって CBZ が無い状態を手で作る
    File.mkdir_p!(Storage.title_dir(author.id, 15))

    meta = %{
      "status" => "published",
      "access_level" => "public",
      "author_id" => author.id,
      "title_id" => 15,
      "episode_id" => 1
    }

    File.write!(Storage.settings_path(author.id, 15, 1), Jason.encode!(meta))

    conn = build_conn() |> internal() |> get("/api/public/cbz/#{author.id}/15/1.cbz")
    assert json_response(conn, 404) == %{"detail" => "CBZファイルが見つかりません"}
  end

  test "サムネイルと表紙の執行と 404", %{
    author: author
  } do
    conn = build_conn() |> internal() |> get("/api/public/thumb/#{author.id}/11/1/0")
    assert conn.status == 200
    assert conn.resp_body == "THUMB-11-0"

    conn = build_conn() |> internal() |> get("/api/public/thumb/#{author.id}/14/1/0")
    assert json_response(conn, 403) == %{"detail" => "非公開です"}

    conn = build_conn() |> internal() |> get("/api/public/thumb/#{author.id}/99/1/0")
    assert json_response(conn, 404) == %{"detail" => "作品が見つかりません"}

    conn = build_conn() |> internal() |> get("/api/public/thumb/#{author.id}/11/1/9")
    assert json_response(conn, 404) == %{"detail" => "サムネイルが見つかりません"}

    # 許可制のサムネイルも匿名は 401
    conn = build_conn() |> internal() |> get("/api/public/thumb/#{author.id}/12/1/0")
    assert json_response(conn, 401) == %{"detail" => "この作品を読むにはログインが必要です"}

    conn = build_conn() |> internal() |> get("/api/public/cover/#{author.id}/11/1")
    assert conn.status == 200

    conn = build_conn() |> internal() |> get("/api/public/cover/#{author.id}/13/1")
    assert json_response(conn, 403) == %{"detail" => "年齢確認が必要な作品の表紙は表示できません"}

    conn = build_conn() |> internal() |> get("/api/public/cover/#{author.id}/14/1")
    assert json_response(conn, 403) == %{"detail" => "非公開です"}
  end

  test "config は base_url を返す" do
    conn = get(build_conn(), "/api/config")
    assert json_response(conn, 200) == %{"platform_base_url" => "http://www.example.com"}
  end

  test "カタログと CBZ のレート制限（内部は免除、CF の IP で数える）", %{author: author} do
    old = System.get_env("MANGA_TRUST_CF_HEADER")
    System.put_env("MANGA_TRUST_CF_HEADER", "1")

    on_exit(fn ->
      if old,
        do: System.put_env("MANGA_TRUST_CF_HEADER", old),
        else: System.delete_env("MANGA_TRUST_CF_HEADER")
    end)

    cf = fn conn, ip -> put_req_header(conn, "cf-connecting-ip", ip) end

    for _ <- 1..5 do
      conn = build_conn() |> cf.("198.51.100.7") |> get("/api/public/catalog")
      assert conn.status == 200
    end

    conn = build_conn() |> cf.("198.51.100.7") |> get("/api/public/catalog")
    assert conn.status == 429
    assert conn.resp_body =~ "リクエストが多すぎます"

    url = "/api/public/cbz/#{author.id}/11/1.cbz"

    for _ <- 1..10 do
      conn = build_conn() |> cf.("198.51.100.8") |> get(url)
      assert conn.status == 200
    end

    conn = build_conn() |> cf.("198.51.100.8") |> get(url)
    assert conn.status == 429
  end
end
