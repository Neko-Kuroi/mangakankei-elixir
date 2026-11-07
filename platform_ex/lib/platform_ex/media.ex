defmodule PlatformEx.Media do
  @moduledoc """
  画像加工の部屋：リサイズ・サムネイル・表紙・CBZ 化。
  寸法と手順は Python 版（PIL）の処理に寄せる。

  - リサイズは「収まる範囲に縮小のみ」（PIL の thumbnail と同じ式と丸め）
  - PNG/JPEG のバイト列そのものはエンコーダの違いで Python 版と一致しない。
    一致するのは画素と寸法（閲覧は画素で復号されるため）
  """
  alias PlatformEx.Media.Scramble

  @display_max {1200, 1800}
  @thumb_max {150, 220}
  @cover_max {600, 900}

  @charset62 "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  # ---------------------------------------------------------------------------
  # ファイル名（Python 版 generate_page_filename と同じ）
  # ---------------------------------------------------------------------------

  def page_filename(index) do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    to_base62(index, 4) <> random <> ".png"
  end

  def to_base62(n, width) do
    digits =
      if n == 0 do
        "0"
      else
        n |> digits62([]) |> Enum.join()
      end

    String.pad_leading(digits, width, "0")
  end

  defp digits62(0, acc), do: acc

  defp digits62(n, acc) do
    digits62(div(n, 62), [String.at(@charset62, rem(n, 62)) | acc])
  end

  @doc "ファイル名[4:12] を16進として解釈したスクランブルの種（Python 版と同じ）"
  def seed_from_filename(filename) do
    filename |> binary_part(4, 8) |> Integer.parse(16) |> elem(0)
  end

  # ---------------------------------------------------------------------------
  # PIL の thumbnail と同じ寸法計算（縮小のみ、比率維持）。
  # 丸めは Pillow の round_aspect：切り捨てと切り上げのうち、
  # 元の縦横比に近くなる方を選び、同点なら切り捨て（Pillow 13 の実装どおり）
  # ---------------------------------------------------------------------------

  def fit_dims(w, h, {max_w, max_h}) do
    if max_w >= w and max_h >= h do
      {w, h}
    else
      aspect = w / h

      if max_w / max_h >= aspect do
        {round_aspect(max_h * aspect, fn n -> abs(aspect - n / max_h) end), max_h}
      else
        key = fn
          0 -> 0
          n -> abs(aspect - max_w / n)
        end

        {max_w, round_aspect(max_w / aspect, key)}
      end
    end
  end

  defp round_aspect(number, key) do
    lo = trunc(Float.floor(number))
    hi = trunc(Float.ceil(number))
    chosen = if key.(hi) < key.(lo), do: hi, else: lo
    max(chosen, 1)
  end

  # ---------------------------------------------------------------------------
  # 画像の読み込みと加工
  # ---------------------------------------------------------------------------

  @doc "画像を開いて RGB（3バンド、αなし）にする。PIL の convert(\"RGB\") 相当"
  def open_rgb(path) do
    img = Image.open!(path)
    img = if Image.has_alpha?(img), do: drop_alpha(img), else: img

    if Image.bands(img) == 3 and Image.colorspace(img) == :srgb do
      img
    else
      Image.to_colorspace!(img, :srgb)
    end
  end

  # PIL の convert("RGB") は α を合成せずに落とす（RGB の値はそのまま）
  defp drop_alpha(img) do
    bands = Image.bands(img)
    Vix.Vips.Operation.extract_band!(img, 0, n: bands - 1)
  end

  @doc "表示用に縮小する（1200x1800 に収まるまで、拡大はしない）"
  def resize_for_display(img), do: resize_to_fit(img, @display_max)

  @doc "サムネイル寸法に縮小する（150x220）"
  def resize_for_thumb(img), do: resize_to_fit(img, @thumb_max)

  @doc "表紙寸法に縮小する（600x900）"
  def resize_for_cover(img), do: resize_to_fit(img, @cover_max)

  defp resize_to_fit(img, max) do
    {w, h} = {Image.width(img), Image.height(img)}

    case fit_dims(w, h, max) do
      {^w, ^h} -> img
      {new_w, new_h} -> Image.resize!(img, new_w / w, vertical_scale: new_h / h)
    end
  end

  def scramble(img, seed, tile_size), do: Scramble.scramble(img, seed, tile_size)

  def save_png(img, path), do: Image.write!(img, path)
  def save_jpeg(img, path, quality), do: Image.write!(img, path, quality: quality)

  @doc """
  CBZ を作る（ZIP_STORED、エントリは与えた順）。
  entries は {アーカイブ名, ファイルパス} のリスト。
  """
  def write_cbz(zip_path, entries) do
    zip_entries =
      Enum.map(entries, fn {arcname, path} ->
        {String.to_charlist(arcname), File.read!(path)}
      end)

    {:ok, _} =
      :zip.create(String.to_charlist(zip_path), zip_entries, uncompress: :all)

    :ok
  end
end
