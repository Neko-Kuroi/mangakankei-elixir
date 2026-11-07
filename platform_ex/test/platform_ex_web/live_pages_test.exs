defmodule PlatformExWeb.LivePagesTest do
  @moduledoc "手順5：画面（カタログ・ログイン・作者ダッシュボード・管理）の検証"
  use PlatformExWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias PlatformEx.{Accounts, Jobs, LegacySchema, Works}

  setup do
    LegacySchema.setup!()

    root =
      Path.join(System.tmp_dir!(), "live_pages_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old_storage = Application.get_env(:platform_ex, :storage_dir)
    Application.put_env(:platform_ex, :storage_dir, root)
    old_admin = System.get_env("MANGA_ADMIN_USERS")

    on_exit(fn ->
      if old_storage,
        do: Application.put_env(:platform_ex, :storage_dir, old_storage),
        else: Application.delete_env(:platform_ex, :storage_dir)

      if old_admin,
        do: System.put_env("MANGA_ADMIN_USERS", old_admin),
        else: System.delete_env("MANGA_ADMIN_USERS")

      File.rm_rf!(root)
    end)

    {:ok, author} = register("lv_author", "author")
    {:ok, reader} = register("lv_reader", "reader")
    {:ok, admin} = register("lv_admin", "author")

    # 管理者名は予約名として登録拒否されるため、ユーザーを作ってから env を指す
    System.put_env("MANGA_ADMIN_USERS", "lv_admin")

    # レート制限（IP 単位）はテスト間で共有されるため、IP をテストごとに変える
    ip = {10, 9, 8, :erlang.unique_integer([:positive]) |> rem(250) |> Kernel.+(1)}
    {:ok, root: root, author: author, reader: reader, admin: admin, ip: ip}
  end

  defp fresh_conn(ip), do: %{build_conn() | remote_ip: ip}

  defp register(name, type) do
    Accounts.register_user(%{
      "username" => name,
      "email" => "#{name}@example.com",
      "password" => "password123",
      "account_type" => type
    })
  end

  defp png_file(root, name) do
    path = Path.join(root, name)
    Image.new!(120, 90, color: [200, 40, 40]) |> Image.write!(path)
    %{path: path, filename: name}
  end

  defp make_work(root, author, tid, eid, settings) do
    file = png_file(root, "w#{tid}_#{eid}.png")
    {:ok, job_id, _} = Works.start_upload(author, tid, eid, [file], nil, false, 16)
    wait_job(job_id)
    :ok = Works.update_settings(author, tid, eid, settings)
    :ok
  end

  defp wait_job(job_id, tries \\ 100) do
    case Jobs.get(job_id) do
      {:ok, %{"phase" => "done"}} ->
        Jobs.pop(job_id)
        :ok

      {:ok, %{"phase" => "error"} = p} ->
        raise "job failed: #{inspect(p)}"

      _ when tries > 0 ->
        Process.sleep(50)
        wait_job(job_id, tries - 1)

      _ ->
        raise "job timeout"
    end
  end

  defp login(conn, username) do
    conn = post(conn, "/session", %{"username" => username, "password" => "password123"})
    assert redirected_to(conn) == "/author"
    conn
  end

  # ---------------------------------------------------------------------------
  # カタログとログイン
  # ---------------------------------------------------------------------------

  test "カタログに公開作品だけが出る", %{conn: conn, root: root, author: author} do
    base = %{
      "status" => "published",
      "access_level" => "public",
      "title_name" => "公開タイトル",
      "episode_name" => "第1話",
      "caption" => "",
      "comment" => "",
      "note" => "",
      "scrambled" => false,
      "tile_size" => 16,
      "webhook_enabled" => false,
      "age_restricted" => false
    }

    make_work(root, author, 11, 1, base)
    make_work(root, author, 12, 1, %{base | "status" => "draft", "title_name" => "下書きタイトル"})

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "公開タイトル"
    refute html =~ "下書きタイトル"
  end

  test "ログイン画面とセッション（失敗・成功・ログアウト）", %{ip: ip} do
    conn = get(fresh_conn(ip), "/login")
    assert html_response(conn, 200) =~ "ログインする"
    assert html_response(conn, 200) =~ "アカウントを登録"

    conn = fresh_conn(ip)
    conn = post(conn, "/session", %{"username" => "lv_author", "password" => "wrong-pass"})
    assert redirected_to(conn) == "/login"
    conn = get(conn, "/login")
    assert html_response(conn, 200) =~ "ユーザー名またはパスワードが正しくありません"

    conn = fresh_conn(ip) |> login("lv_author")
    conn = post(conn, "/session/logout")
    assert redirected_to(conn) == "/"

    conn = fresh_conn(ip) |> login("lv_author")
    {:ok, _view, html} = live(conn, "/author")
    assert html =~ "マイ作品管理"
  end

  test "画面の新規登録でユーザーが作られる", %{conn: conn} do
    conn =
      post(conn, "/session/signup", %{
        "username" => "lv_newbie",
        "email" => "lv_newbie@example.com",
        "password" => "password123",
        "account_type" => "reader"
      })

    assert redirected_to(conn) == "/login"
    assert Accounts.get_user_by_username("lv_newbie").account_type == "reader"
  end

  test "未ログインで /author へ行くと /login に戻される", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/author")
  end

  # ---------------------------------------------------------------------------
  # 作者ダッシュボード
  # ---------------------------------------------------------------------------

  test "編集・許可・削除が画面からできる", %{ip: ip, root: root, author: author} do
    conn = fresh_conn(ip)

    make_work(root, author, 21, 1, %{
      "status" => "draft",
      "access_level" => "premium",
      "title_name" => "編集タイトル",
      "episode_name" => "第1話",
      "caption" => "",
      "comment" => "",
      "note" => "",
      "scrambled" => false,
      "tile_size" => 16,
      "webhook_enabled" => false,
      "age_restricted" => false
    })

    conn = login(conn, "lv_author")
    {:ok, view, html} = live(conn, "/author")
    assert html =~ "編集タイトル"
    assert html =~ "下書き"

    # 編集：公開にする
    view |> element("button", "✏️ 編集") |> render_click()
    assert render(view) =~ "エピソード編集"

    view
    |> form("#edit-form", %{"status" => "published", "title_name" => "編集タイトル改"})
    |> render_submit()

    assert render(view) =~ "編集タイトル改"
    assert render(view) =~ "公開中"

    # 許可：読者を追加して取り消す
    view |> element("button", "🔑 閲覧許可") |> render_click()
    assert render(view) =~ "許可しているユーザーはいません"

    view |> form("#grant-form", %{"username" => "lv_reader"}) |> render_submit()
    assert render(view) =~ "lv_reader"

    view |> element("button", "取り消し") |> render_click()
    assert render(view) =~ "許可しているユーザーはいません"
    view |> element("button", "閉じる") |> render_click()

    # 削除
    view |> element("button", "🗑️ 削除") |> render_click()
    assert render(view) =~ "削除の確認"
    view |> element("button", "削除する") |> render_click()
    refute render(view) =~ "編集タイトル改"
  end

  test "画面からのアップロードで作品ができる", %{ip: ip, root: root} do
    src = png_file(root, "upload_src.png")
    bytes = File.read!(src.path)

    conn = fresh_conn(ip) |> login("lv_author")
    {:ok, view, _html} = live(conn, "/author")

    upload =
      file_input(view, "#upload-form", :pages, [
        %{name: "page1.png", content: bytes, type: "image/png"}
      ])

    assert render_upload(upload, "page1.png") =~ "page1.png"

    view
    |> form("#upload-form", %{
      "title_name" => "画面アップ作品",
      "episode_name" => "第1話",
      "title_id" => "31",
      "episode_id" => "1",
      "status" => "published"
    })
    |> render_submit()

    html = wait_for_text(view, "アップロードと設定の保存が完了しました")
    assert html =~ "画面アップ作品"
    assert Works.list_works(Accounts.get_user_by_username("lv_author")) != []
  end

  defp wait_for_text(view, text, tries \\ 60) do
    html = render(view)

    cond do
      html =~ text ->
        html

      tries > 0 ->
        Process.sleep(200)
        wait_for_text(view, text, tries - 1)

      true ->
        raise "timeout waiting for: #{text}\nlast html: #{String.slice(html, 0, 500)}"
    end
  end

  # ---------------------------------------------------------------------------
  # 管理
  # ---------------------------------------------------------------------------

  test "管理者は停止と解除ができ、非管理者は入られない", %{
    ip: ip,
    root: root,
    author: author
  } do
    conn = fresh_conn(ip)

    make_work(root, author, 41, 1, %{
      "status" => "published",
      "access_level" => "public",
      "title_name" => "管理対象",
      "episode_name" => "第1話",
      "caption" => "",
      "comment" => "",
      "note" => "",
      "scrambled" => false,
      "tile_size" => 16,
      "webhook_enabled" => false,
      "age_restricted" => false
    })

    # 作者（非管理者）は / へ戻される
    author_conn = login(fresh_conn(ip), "lv_author")
    assert {:error, {:redirect, %{to: "/"}}} = live(author_conn, "/admin")

    conn = login(conn, "lv_admin")
    {:ok, view, html} = live(conn, "/admin")
    assert html =~ "管理対象"

    view
    |> form("form[phx-submit='suspend']", %{"reason" => "規約違反"})
    |> render_submit()

    assert render(view) =~ "公開停止中"
    assert render(view) =~ "規約違反"

    view |> element("button", "解除する") |> render_click()
    refute render(view) =~ "公開停止中"
  end
end
