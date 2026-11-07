defmodule PlatformEx.WorksTest do
  use PlatformEx.DataCase, async: false

  alias PlatformEx.{Jobs, LegacySchema, Storage, Works}
  alias PlatformEx.Accounts.User

  setup do
    LegacySchema.setup!()

    root =
      Path.join(
        System.tmp_dir!(),
        "works_test_#{:erlang.unique_integer([:positive])}"
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

    {:ok, root: root, user: %User{id: 42, username: "worker", email: "w@example.com"}}
  end

  defp write_image(path, w, h, color \\ [120, 30, 200]) do
    Image.new!(w, h, color: color) |> Image.write!(path)
    path
  end

  defp spool_file(root, name, src) do
    dest = Path.join(root, name)
    File.cp!(src, dest)
    dest
  end

  test "natural_key は数字を数として、小文字化して比べる" do
    names = ["p10.png", "p2.png", "P1.png", "p10a.png"]
    sorted = Enum.sort_by(names, &Works.natural_key/1)
    assert sorted == ["P1.png", "p2.png", "p10.png", "p10a.png"]
    assert Enum.sort_by(["10.png", "2.png"], &Works.natural_key/1) == ["2.png", "10.png"]
  end

  test "process_upload：並べ替え・加工・CBZ・サムネイル・進捗 done", %{root: root, user: user} do
    job = Jobs.new_job_id()
    Jobs.update(job, "queued", 0, 3)

    spool = Path.join(root, "spool")
    File.mkdir_p!(spool)

    files = [
      {"c_page.png", spool_file(spool, "up2", write_image(Path.join(root, "c.png"), 100, 80))},
      {"a_page.jpg", spool_file(spool, "up0", write_image(Path.join(root, "a.jpg"), 2000, 1500))},
      {"b_page.png", spool_file(spool, "up1", write_image(Path.join(root, "b.png"), 100, 80))}
    ]

    cover_src = write_image(Path.join(root, "cover.jpg"), 300, 400)
    cover = {spool_file(spool, "cover_upload", cover_src), "cover.jpg"}

    Works.process_upload(job, 5, 2, files, cover, true, 16, user.id, spool)

    assert {:ok, progress} = Jobs.get(job)
    assert progress["phase"] == "done"
    assert progress["page_count"] == 3
    assert progress["scrambled"] == true
    assert progress["tile_size"] == 16

    cbz = Storage.cbz_path(user.id, 5, 2)
    assert File.exists?(cbz)
    {:ok, entries} = :zip.unzip(String.to_charlist(cbz), [:memory])
    assert length(entries) == 3

    # 1ページ目（a_page.jpg が自然順で先頭）は 1200x900 に縮小されている
    {first_name, first_bin} = hd(entries)
    assert Regex.match?(~r/^0000[0-9a-f]{16}\.png$/, List.to_string(first_name))
    first_path = Path.join(root, "first.png")
    File.write!(first_path, first_bin)
    first_img = Image.open!(first_path)
    assert {Image.width(first_img), Image.height(first_img)} == {1200, 900}

    # サムネイルは3枚、寸法は 150x220 の枠内
    thumbs = File.ls!(Storage.thumbs_dir(user.id, 5, 2))
    assert Enum.sort(thumbs) == ["thumb_0000.jpg", "thumb_0001.jpg", "thumb_0002.jpg"]

    thumb_img = Image.open!(Storage.thumb_path(user.id, 5, 2, 0))
    # 1200x900 → 150x220 枠：幅制限で 150x113（PIL の round_aspect）
    assert {Image.width(thumb_img), Image.height(thumb_img)} == {150, 113}

    # 表紙は 600x900 の枠内（300x400 はそのまま）
    cover_img = Image.open!(Storage.cover_path(user.id, 5, 2))
    assert {Image.width(cover_img), Image.height(cover_img)} == {300, 400}

    # スプールは片付けられる
    refute File.exists?(spool)
  end

  test "process_upload：画像が無ければ error 進捗になる", %{root: root, user: user} do
    job = Jobs.new_job_id()
    spool = Path.join(root, "spool2")
    File.mkdir_p!(spool)
    txt = Path.join(spool, "upload_0000")
    File.write!(txt, "not an image")

    Works.process_upload(job, 5, 3, [{"note.txt", txt}], nil, true, 16, user.id, spool)

    assert {:ok, progress} = Jobs.get(job)
    assert progress["phase"] == "error"
    assert progress["message"] == "有効な画像ファイルがありませんでした"
  end

  test "settings の保存・一覧・削除", %{user: user} do
    base = %{
      "status" => "draft",
      "access_level" => "public",
      "title_name" => "作品X",
      "episode_name" => "第1話",
      "caption" => "",
      "comment" => "",
      "note" => "",
      "scrambled" => true,
      "tile_size" => 16,
      "webhook_enabled" => false,
      "age_restricted" => false
    }

    # 下書きは CBZ が無くても保存できる
    assert :ok = Works.update_settings(user, 9, 1, base)

    works = Works.list_works(user)
    assert length(works) == 1
    work = hd(works)
    assert work["title_name"] == "作品X"
    assert work["has_cbz"] == false
    assert work["has_cover"] == false
    assert work["suspended"] == false
    created = work["created_at"]
    assert is_float(created)

    # 公開は CBZ が無いと 400
    assert {:error, 400, "先に原稿をアップロードしてください"} =
             Works.update_settings(user, 9, 1, %{base | "status" => "published"})

    # CBZ を置けば公開でき、created_at は保たれる
    File.mkdir_p!(Storage.title_dir(user.id, 9))
    File.write!(Storage.cbz_path(user.id, 9, 1), "fake cbz")
    assert :ok = Works.update_settings(user, 9, 1, %{base | "status" => "published"})
    [work2] = Works.list_works(user)
    assert work2["status"] == "published"
    assert work2["has_cbz"] == true
    assert work2["created_at"] == created

    # 削除
    assert {:ok, deleted} = Works.delete_episode(user, 9, 1)
    assert "episode_1.cbz" in deleted
    assert "episode_1_settings.json" in deleted
    assert Works.list_works(user) == []

    assert {:error, 404, "削除対象のファイルが見つかりません"} =
             Works.delete_episode(user, 9, 1)
  end
end
