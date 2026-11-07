defmodule PlatformExWeb.AuthorControllerTest do
  use PlatformExWeb.ConnCase, async: false

  alias PlatformEx.{Accounts, LegacySchema, Storage}

  setup do
    LegacySchema.setup!()

    root =
      Path.join(
        System.tmp_dir!(),
        "author_ctrl_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    old = Application.get_env(:platform_ex, :storage_dir)
    Application.put_env(:platform_ex, :storage_dir, root)

    on_exit(fn ->
      if old,
        do: Application.put_env(:platform_ex, :storage_dir, old),
        else: Application.delete_env(:platform_ex, :storage_dir)

      File.rm_rf!(root)
    end)

    {:ok, author} = register("author_a", "author")
    {:ok, reader} = register("reader_a", "reader")

    {:ok,
     root: root,
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

  defp uniq(prefix), do: "#{prefix}_#{:erlang.unique_integer([:positive])}"

  defp auth(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp make_upload(root, filename, w \\ 100, h \\ 80) do
    path = Path.join(root, uniq("src") <> "_" <> filename)
    Image.new!(w, h, color: [10, 120, 60]) |> Image.write!(path)
    %Plug.Upload{path: path, filename: filename, content_type: "image/png"}
  end

  defp poll_done(_conn, token, job_id, tries \\ 40) do
    conn =
      build_conn()
      |> auth(token)
      |> get("/api/author/upload-progress/#{job_id}")

    case json_response(conn, 200) do
      %{"phase" => "done"} = progress ->
        progress

      %{"phase" => "error"} = progress ->
        raise "job failed: #{inspect(progress)}"

      _ when tries > 0 ->
        Process.sleep(100)
        poll_done(conn, token, job_id, tries - 1)

      other ->
        raise "job did not finish: #{inspect(other)}"
    end
  end

  test "works は最初は空。読者は 403、無認証は 401", %{
    author_token: at,
    reader_token: rt
  } do
    conn = build_conn() |> auth(at) |> get("/api/author/works")
    assert json_response(conn, 200) == []

    conn = build_conn() |> auth(rt) |> get("/api/author/works")
    assert json_response(conn, 403) == %{"detail" => "読者アカウントでは利用できません"}

    conn = get(build_conn(), "/api/author/works")
    assert json_response(conn, 401) == %{"detail" => "Not authenticated"}
  end

  test "アップロード→進捗 done（読み取り時に消える）→設定→一覧→配信→削除", %{
    root: root,
    author: author,
    author_token: at
  } do
    uploads = [make_upload(root, "p2.png"), make_upload(root, "p1.jpg", 2000, 1500)]
    cover = make_upload(root, "cover.jpg", 300, 400)

    conn =
      build_conn()
      |> auth(at)
      |> put_req_header("content-type", "multipart/form-data")
      |> post("/api/author/titles/701/episodes/1/upload-and-zip?do_scramble=true&tile_size=16", %{
        "files" => uploads,
        "cover" => cover
      })

    body = json_response(conn, 200)
    assert body["total_files"] == 2
    job_id = body["job_id"]
    assert Regex.match?(~r/^[0-9a-f]{32}$/, job_id)

    progress = poll_done(conn, at, job_id)
    assert progress["page_count"] == 2
    assert progress["scrambled"] == true
    assert progress["tile_size"] == 16

    # done は一度読むと消える
    conn = build_conn() |> auth(at) |> get("/api/author/upload-progress/#{job_id}")
    assert json_response(conn, 404) == %{"detail" => "job not found"}

    # 設定を公開にする
    conn =
      build_conn()
      |> auth(at)
      |> put_req_header("content-type", "application/json")
      |> patch(
        "/api/author/titles/701/episodes/1/settings",
        Jason.encode!(%{
          "status" => "published",
          "access_level" => "public",
          "title_name" => "テスト作品"
        })
      )

    assert json_response(conn, 200) == %{"status" => "success"}

    conn = build_conn() |> auth(at) |> get("/api/author/works")
    [work] = json_response(conn, 200)
    assert work["title_name"] == "テスト作品"
    assert work["has_cbz"] == true
    assert work["has_cover"] == true

    # preview / thumb / cover（?token= 認証）
    token = PlatformEx.Auth.Token.issue(author.id)

    conn = get(build_conn(), "/api/author/preview/701/1.cbz?token=#{token}")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"

    assert get_resp_header(conn, "content-disposition") |> hd() =~
             ~s(filename="preview_t701_ep1.cbz")

    preview_path = Path.join(root, "preview_download.cbz")
    File.write!(preview_path, conn.resp_body)
    {:ok, entries} = :zip.unzip(String.to_charlist(preview_path), [:memory])
    assert length(entries) == 2

    conn = get(build_conn(), "/api/author/thumb/701/1/0?token=#{token}")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"

    conn = get(build_conn(), "/api/author/cover/701/1?token=#{token}")
    assert conn.status == 200

    # token が無ければ 422、読者 token は 403、無い話数は 404
    conn = get(build_conn(), "/api/author/cover/701/1")
    assert json_response(conn, 422)

    conn = get(build_conn(), "/api/author/thumb/701/9/0?token=#{token}")
    assert json_response(conn, 404) == %{"detail" => "サムネイルが見つかりません"}

    # 削除
    conn = build_conn() |> auth(at) |> delete("/api/author/titles/701/episodes/1")
    body = json_response(conn, 200)
    assert body["status"] == "success"
    assert "episode_1.cbz" in body["deleted"]
    assert "thumbs/" in body["deleted"]

    conn = build_conn() |> auth(at) |> delete("/api/author/titles/701/episodes/1")
    assert json_response(conn, 404) == %{"detail" => "削除対象のファイルが見つかりません"}

    _ = Storage.zips_dir()
  end

  test "アップロードの検証：tile_size の範囲と形式、files 必須", %{
    root: root,
    author_token: at
  } do
    upload = make_upload(root, "only.png")

    conn =
      build_conn()
      |> auth(at)
      |> put_req_header("content-type", "multipart/form-data")
      |> post("/api/author/titles/702/episodes/1/upload-and-zip?tile_size=24", %{
        "files" => [upload]
      })

    assert json_response(conn, 400) == %{
             "detail" => "tile_size は (8, 16, 32) のいずれかにしてください（受信値: 24）"
           }

    conn =
      build_conn()
      |> auth(at)
      |> put_req_header("content-type", "multipart/form-data")
      |> post("/api/author/titles/702/episodes/1/upload-and-zip?tile_size=abc", %{
        "files" => [upload]
      })

    body = json_response(conn, 422)
    assert hd(body["detail"])["type"] == "int_parsing"

    conn =
      build_conn()
      |> auth(at)
      |> put_req_header("content-type", "multipart/form-data")
      |> post("/api/author/titles/702/episodes/1/upload-and-zip", %{})

    body = json_response(conn, 422)
    assert hd(body["detail"])["loc"] == ["body", "files"]
  end

  test "設定の検証：CBZ 無しの公開は 400、必須欠けは 422、tile_size 範囲は 400", %{
    author_token: at
  } do
    patch_settings = fn body ->
      build_conn()
      |> auth(at)
      |> put_req_header("content-type", "application/json")
      |> patch("/api/author/titles/703/episodes/1/settings", Jason.encode!(body))
    end

    conn = patch_settings.(%{"status" => "published", "access_level" => "public"})
    assert json_response(conn, 400) == %{"detail" => "先に原稿をアップロードしてください"}

    conn = patch_settings.(%{"access_level" => "public"})
    body = json_response(conn, 422)
    assert hd(body["detail"])["loc"] == ["body", "status"]

    conn =
      patch_settings.(%{
        "status" => "draft",
        "access_level" => "public",
        "tile_size" => 24
      })

    assert json_response(conn, 400)["detail"] =~ "tile_size は (8, 16, 32)"
  end
end
