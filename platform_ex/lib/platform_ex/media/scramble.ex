defmodule PlatformEx.Media.Scramble do
  @moduledoc """
  プラットフォーム main.py の scramble_image の移植（手順0スパイクで
  Python 出力・JS 復号との画素一致を検証済みの方式）。
  Xorshift32 + Fisher-Yates + タイル転置。端数領域は無加工。

  タイルの転置は Image.join（vips arrayjoin）で1演算にまとめる。
  compose をタイル数だけ連ねる方式は、1VM 内で大きなスクランブルを
  複数回実行すると segfault する再現があったため採用しない（SPIKE.md 参照）。
  """
  import Bitwise

  @mask 0xFFFFFFFF

  @doc "Xorshift32 の next（Python 版と同じ数列）"
  def next(state) do
    x = state &&& @mask
    x = bxor(x, x <<< 13 &&& @mask)
    x = bxor(x, x >>> 17)
    x = bxor(x, x <<< 5 &&& @mask)
    x &&& @mask
  end

  @doc "xorshift_shuffle(list(range(n)), seed) と同じ並びを %{位置 => 値} で返す"
  def permutation(n, seed) when n >= 2 do
    init = Map.new(0..(n - 1), &{&1, &1})
    state0 = if (seed &&& @mask) == 0, do: 1, else: seed &&& @mask

    {perm, _state} =
      Enum.reduce((n - 1)..1//-1, {init, state0}, fn i, {perm, state} ->
        state = next(state)
        j = rem(state, i + 1)
        vi = Map.fetch!(perm, i)
        vj = Map.fetch!(perm, j)
        {perm |> Map.put(i, vj) |> Map.put(j, vi), state}
      end)

    perm
  end

  @doc "画像にスクランブルをかける（タイル転置、端数はそのまま）"
  def scramble(image, seed, tile_size) do
    w = Image.width(image)
    h = Image.height(image)
    cols = div(w, tile_size)
    rows = div(h, tile_size)
    n = cols * rows

    if n <= 1 do
      image
    else
      perm = permutation(n, seed)
      inverse = Map.new(perm, fn {src, dest} -> {dest, src} end)

      tiles =
        for dest <- 0..(n - 1) do
          src = Map.fetch!(inverse, dest)

          Image.crop!(
            image,
            rem(src, cols) * tile_size,
            div(src, cols) * tile_size,
            tile_size,
            tile_size
          )
        end

      grid = Image.join!(tiles, across: cols)
      Image.compose!(image, grid, x: 0, y: 0)
    end
  end
end
