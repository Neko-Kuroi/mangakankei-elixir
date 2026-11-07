defmodule PlatformEx.MediaTest do
  use ExUnit.Case, async: true

  alias PlatformEx.Media

  @assets Path.join(System.user_home!(), "workspace/platform-spike-assets")

  defp png_bytes(img), do: Image.write!(img, :memory, suffix: ".png")

  test "to_base62 は Python 版と同じ（0埋め4桁）" do
    assert Media.to_base62(0, 4) == "0000"
    assert Media.to_base62(1, 4) == "0001"
    assert Media.to_base62(61, 4) == "000z"
    assert Media.to_base62(62, 4) == "0010"
    assert Media.to_base62(123, 4) == "001z"
  end

  test "page_filename の形と seed の導出" do
    name = Media.page_filename(7)
    assert Regex.match?(~r/^[0-9A-Za-z]{4}[0-9a-f]{16}\.png$/, name)
    assert String.slice(name, 0, 4) == "0007"
    seed = Media.seed_from_filename("Ab3d0123456789abcdef.png")
    assert seed == 0x01234567
  end

  test "fit_dims は PIL の thumbnail と同じ（縮小のみ・round_aspect）" do
    # 収まっていればそのまま
    assert Media.fit_dims(100, 80, {1200, 1800}) == {100, 80}
    assert Media.fit_dims(1200, 1800, {1200, 1800}) == {1200, 1800}
    # 幅が制限（2000x1500 → 1200x900）
    assert Media.fit_dims(2000, 1500, {1200, 1800}) == {1200, 900}
    # 高さが制限（800x2000 → 720x1800）
    assert Media.fit_dims(800, 2000, {1200, 1800}) == {720, 1800}
    # round_aspect：112.5 は比率が近くなる切り上げ側（113）が選ばれる
    assert Media.fit_dims(1200, 900, {150, 220}) == {150, 113}
    # 同点なら切り捨て
    assert Media.fit_dims(5, 4, {10, 2}) == {2, 2}
    assert Media.fit_dims(7, 4, {10, 2}) == {3, 2}
  end

  for case_name <- ["caseA", "caseB", "caseC"] do
    test "スクランブルが Python 出力と画素一致する #{case_name}" do
      dir = Path.join(@assets, unquote(case_name))
      meta = Jason.decode!(File.read!(Path.join(dir, "meta.json")))
      seed = Media.seed_from_filename(meta["filename"])

      original = Image.open!(Path.join(dir, "original.png"))
      expected = Image.open!(Path.join(dir, "py_scrambled.png"))

      out = Media.scramble(original, seed, meta["tile_size"])
      assert Image.width(out) == meta["width"]
      assert Image.height(out) == meta["height"]
      assert png_bytes(out) == png_bytes(expected)
    end
  end

  test "write_cbz は STORED でエントリ順と中身を保つ" do
    tmp = Path.join(System.tmp_dir!(), "cbz_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    a = Path.join(tmp, "a.bin")
    b = Path.join(tmp, "b.bin")
    File.write!(a, "first")
    File.write!(b, "second")
    zip = Path.join(tmp, "out.cbz")

    assert :ok = Media.write_cbz(zip, [{"0000.png", a}, {"0001.png", b}])

    {:ok, entries} = :zip.unzip(String.to_charlist(zip), [:memory])
    assert entries == [{~c"0000.png", "first"}, {~c"0001.png", "second"}]
    File.rm_rf!(tmp)
  end

  test "open_rgb は α を落として3バンドにする" do
    tmp = Path.join(System.tmp_dir!(), "rgba_#{:erlang.unique_integer([:positive])}.png")
    img = Image.new!(10, 10, color: [200, 100, 50, 128])
    Image.write!(img, tmp)

    rgb = Media.open_rgb(tmp)
    assert Image.bands(rgb) == 3
    # PIL の convert("RGB") は合成しないので RGB 値はそのまま
    expected = Image.new!(10, 10, color: [200, 100, 50])
    assert png_bytes(rgb) == png_bytes(expected)
    File.rm!(tmp)
  end
end
