defmodule YomimaEx.MangaTest do
  use ExUnit.Case, async: true

  alias YomimaEx.Manga

  describe "safe_filename/3（Python 版 get_safe_filename のなぞり）" do
    test "通常ファイルは {index:05d}_{stem}{ext}" do
      assert Manga.safe_filename("page01.png", 0, ".png") == "00000_page01.png"
      assert Manga.safe_filename("dir/sub/page04.png", 3, ".png") == "00003_page04.png"
    end

    test "スクランブル命名規則（stem=20文字＋hex）はそのまま保持" do
      assert Manga.safe_filename("Ab3d0123456789abcdef.png", 7, ".png") ==
               "Ab3d0123456789abcdef.png"
    end

    test "20文字でも hex でなければプレフィックスが付く" do
      assert Manga.safe_filename("zzzzzzzzzzzzzzzzzzzz.png", 1, ".png") ==
               "00001_zzzzzzzzzzzzzzzzzzzz.png"
    end

    test "危険文字は _ に置換され、stem は40文字で切られる" do
      assert Manga.safe_filename("my file#1.jpg", 2, ".jpg") == "00002_my_file_1.jpg"

      long = String.duplicate("a", 50) <> ".png"
      assert Manga.safe_filename(long, 0, ".png") ==
               "00000_" <> String.duplicate("a", 40) <> ".png"
    end

    test "バックスラッシュ区切りのパスも basename 化される" do
      assert Manga.safe_filename("dir\\page02.png", 5, ".png") == "00005_page02.png"
    end
  end

  describe "scrambled_filename?/1（Python 版 is_scrambled_filename のなぞり）" do
    test "20文字 stem＋16文字 hex で true" do
      assert Manga.scrambled_filename?("Ab3d0123456789abcdef.png")
      assert Manga.scrambled_filename?("/some/dir/Ab3d0123456789abcdef.png")
    end

    test "それ以外は false" do
      refute Manga.scrambled_filename?("00000_page01.png")
      refute Manga.scrambled_filename?("zzzzzzzzzzzzzzzzzzzz.png")
      refute Manga.scrambled_filename?("Ab3d0123456789abcde.png")
    end
  end

  describe "load_image_bytes/3（Python 版 load_image_bytes のなぞり）" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "yomima_ex_manga_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      System.put_env("MANGA_CACHE_DIR", Path.join(tmp, "cache"))
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    defp write_image!(tmp, name, w, h, color) do
      path = Path.join(tmp, name)
      {:ok, img} = Image.new(w, h, color: color)
      {:ok, _} = Image.write(img, path)
      path
    end

    defp dims(data) do
      {:ok, img} = Image.open(data)
      {Image.width(img), Image.height(img)}
    end

    test "存在しないファイルは nil", %{tmp: tmp} do
      assert Manga.load_image_bytes(Path.join(tmp, "nope.png"), {80, 120}) == nil
    end

    test "RGB は {80, 120} に収まる JPEG になる", %{tmp: tmp} do
      path = write_image!(tmp, "page.jpg", 400, 600, [220, 40, 40])
      data = Manga.load_image_bytes(path, {80, 120})
      assert <<0xFF, 0xD8, 0xFF, _::binary>> = data
      assert dims(data) == {80, 120}
    end

    test "小さい画像は拡大しない", %{tmp: tmp} do
      path = write_image!(tmp, "small.jpg", 40, 60, [10, 200, 10])
      data = Manga.load_image_bytes(path, {80, 120})
      assert dims(data) == {40, 60}
    end

    test "アルファ付きは PNG になる", %{tmp: tmp} do
      path = write_image!(tmp, "alpha.png", 200, 200, [40, 220, 40, 128])
      data = Manga.load_image_bytes(path, {80, 120})
      assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>> = data
      assert dims(data) == {80, 80}
    end

    test "スクランブル命名はリサイズしない", %{tmp: tmp} do
      path = write_image!(tmp, "Ab3d0123456789abcdef.png", 300, 450, [30, 30, 200])
      data = Manga.load_image_bytes(path, {80, 120})
      assert dims(data) == {300, 450}
    end

    test "2回目はキャッシュから同じバイト列が返る", %{tmp: tmp} do
      path = write_image!(tmp, "cached.jpg", 400, 600, [1, 2, 3])
      first = Manga.load_image_bytes(path, {80, 120})
      cache_files = File.ls!(Path.join([tmp, "cache", "thumbs"]))
      assert length(cache_files) == 1
      assert Manga.load_image_bytes(path, {80, 120}) == first
    end
  end

  describe "fetch_allowed?/1（Python 版 fetch_policy_check のなぞり）" do
    test "プラットフォームのオリジンは許可" do
      assert Manga.fetch_allowed?("http://localhost:8000/api/public/cbz/1/501/1.cbz") ==
               {true, ""}
    end

    test "スキームとホストとポートの検証" do
      assert Manga.fetch_allowed?("ftp://example.com/x.zip") ==
               {false, "http/https のURLだけ取得できます"}

      assert Manga.fetch_allowed?("http:///x.zip") == {false, "ホストがありません"}

      assert Manga.fetch_allowed?("http://example.com:abc/x.zip") ==
               {false, "無効なURLです"}
    end

    test "内部アドレスのリテラルは拒否、公開アドレスは許可" do
      assert Manga.fetch_allowed?("http://127.0.0.1:9999/x.zip") ==
               {false, "内部アドレスへの取得は許可されていません"}

      assert Manga.fetch_allowed?("http://192.168.1.5/x.zip") ==
               {false, "内部アドレスへの取得は許可されていません"}

      assert Manga.fetch_allowed?("http://[::1]/x.zip") ==
               {false, "内部アドレスへの取得は許可されていません"}

      assert Manga.fetch_allowed?("http://203.0.113.10/x.zip") == {true, ""}
    end
  end

  describe "マンガリストの encode/decode（Python 版 encode/decode_manga_list のなぞり）" do
    test "往復で戻る" do
      entries = [
        %{"url" => "https://example.com/a.zip", "title" => "作品A", "added_time" => 1700000000.5},
        %{"url" => "https://example.com/b.cbz", "title" => "b.cbz", "added_time" => 1700000100.25}
      ]

      assert Manga.decode_manga_list(Manga.encode_manga_list(entries)) == {entries, ""}
    end

    test "Python 版が生成した文字列を読める" do
      # ~/venv-manga の Python 版 mg.encode_manga_list で生成した実物
      python_made =
        "eyJtYW5nYV91cmxzIjogW3sidXJsIjogImh0dHBzOi8vZXhhbXBsZS5jb20vYS56aXAiLCAidGl0bGUiOiAiXHU0ZjVjXHU1NGMxQSIsICJhZGRlZF90aW1lIjogMTcwMDAwMDAwMC41fSwgeyJ1cmwiOiAiaHR0cHM6Ly9leGFtcGxlLmNvbS9iLmNieiIsICJ0aXRsZSI6ICJiLmNieiIsICJhZGRlZF90aW1lIjogMTcwMDAwMDEwMC4yNX1dLCAiZXhwb3J0X3RpbWUiOiAxNzk0MDI4OTM0LjI3OTY2ODh9"

      assert {entries, ""} = Manga.decode_manga_list(python_made)
      assert [%{"title" => "作品A"}, %{"title" => "b.cbz"}] = entries
    end

    test "標準 base64（+/ を含む）でも読める" do
      json = ~s({"manga_urls":[{"url":"https://example.com/x.zip","title":"x","added_time":1.5}]})
      assert {[%{"url" => "https://example.com/x.zip"}], ""} =
               Manga.decode_manga_list(Base.encode64(json))
    end

    test "壊れた文字列はデコードエラー" do
      assert {[], msg} = Manga.decode_manga_list("!!!not-base64!!!")
      assert String.starts_with?(msg, "デコードエラー")
    end
  end

  describe "filename_from_url/1 と build_manga_entry/2" do
    test "ファイル名の導出（クエリ除去と % デコード）" do
      assert Manga.filename_from_url("https://example.com/manga.zip") == "manga.zip"

      assert Manga.filename_from_url("https://example.com/dir/%E3%81%82.zip?dl=1") ==
               "あ.zip"
    end

    test "タイトルが空ならファイル名が入る" do
      entry = Manga.build_manga_entry("https://example.com/manga.zip")
      assert entry["title"] == "manga.zip"
      assert entry["url"] == "https://example.com/manga.zip"
      assert is_float(entry["added_time"])

      assert Manga.build_manga_entry("https://example.com/m.zip", "題名")["title"] == "題名"
    end
  end

  describe "discord_webhook_url?/1（Python 版 is_discord_webhook_url のなぞり）" do
    test "正規の Discord Webhook は許可" do
      assert Manga.discord_webhook_url?("https://discord.com/api/webhooks/123/abc")
      assert Manga.discord_webhook_url?("https://ptb.discord.com/api/webhooks/1/a")
      assert Manga.discord_webhook_url?("https://canary.discord.com/api/webhooks/1/a")
      assert Manga.discord_webhook_url?("https://discordapp.com/api/webhooks/1/a")
      assert Manga.discord_webhook_url?("https://discord.com:443/api/webhooks/1/a")
    end

    test "それ以外は拒否" do
      refute Manga.discord_webhook_url?("http://discord.com/api/webhooks/1/a")
      refute Manga.discord_webhook_url?("https://example.com/api/webhooks/1/a")
      refute Manga.discord_webhook_url?("https://discord.com.evil.com/api/webhooks/1/a")
      refute Manga.discord_webhook_url?("https://user@discord.com/api/webhooks/1/a")
      refute Manga.discord_webhook_url?("https://discord.com/other/1/a")
      refute Manga.discord_webhook_url?("https://discord.com:8443/api/webhooks/1/a")
      refute Manga.discord_webhook_url?("https://discord.com:abc/api/webhooks/1/a")
    end
  end

  describe "send_image_to_discord/3（Python 版のなぞり、送信自体はしない範囲）" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "yomima_ex_discord_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "ファイルが無ければその旨だけ返る", %{tmp: tmp} do
      assert Manga.send_image_to_discord(Path.join(tmp, "nope.png"), ["https://example.com/x"]) ==
               ["ファイルが見つかりません"]
    end

    test "空の Webhook は飛ばす", %{tmp: tmp} do
      path = Path.join(tmp, "page.png")
      {:ok, img} = Image.new(10, 10, color: [1, 2, 3])
      {:ok, _} = Image.write(img, path)
      assert Manga.send_image_to_discord(path, [""]) == []
    end

    test "Discord 以外の Webhook はエラーになる", %{tmp: tmp} do
      path = Path.join(tmp, "page.png")
      {:ok, img} = Image.new(10, 10, color: [1, 2, 3])
      {:ok, _} = Image.write(img, path)

      assert Manga.send_image_to_discord(path, ["https://example.com/api/webhooks/x"]) ==
               ["Webhook URL は Discord のものだけ使えます"]
    end
  end
end
