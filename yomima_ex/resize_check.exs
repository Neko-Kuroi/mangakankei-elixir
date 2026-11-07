# 画像リサイズの一致確認: Python 版 load_image_bytes（非スクランブル時）と
# Elixir :image（libvips）の結果寸法・形式を比べる。
# 実行: mix run --no-start resize_check.exs /tmp/resize_check
{:ok, _} = Application.ensure_all_started(:image)

dir = System.argv() |> List.first() || "/tmp/resize_check"

check = fn name ->
  src = Path.join(dir, "#{name}.jpg")
  {:ok, img} = Image.open(src)
  {w, h} = {Image.width(img), Image.height(img)}

  # PIL の img.thumbnail((1200, 1800)) 相当: 枠内に収まる場合だけ縮小
  {:ok, out} =
    if w > 1200 or h > 1800 do
      Image.thumbnail(img, "1200x1800")
    else
      {:ok, img}
    end

  out_path = Path.join(dir, "#{name}_ex.jpg")
  {:ok, _} = Image.write(out, out_path, quality: 90)
  {:ok, written} = Image.open(out_path)
  IO.puts("elixir #{name}: #{w}x#{h} -> #{Image.width(written)}x#{Image.height(written)}")
end

check.("big")
check.("small")
