defmodule PlatformSpike.Scramble do
  @moduledoc """
  手順0スパイク：プラットフォーム main.py の scramble_image の Elixir 版。
  Xorshift32 + Fisher-Yates + タイル転置。端数領域は無加工（Python 版と同じ）。
  画像の読み書きは :image（libvips）。タイルは切り貼りだけなので画素はそのまま移る。
  """
  import Bitwise

  @mask 0xFFFFFFFF

  @doc "Xorshift32 の next（Python 版 Xorshift32.next と同じ数列）"
  def next(state) do
    x = state &&& @mask
    x = bxor(x, x <<< 13 &&& @mask)
    x = bxor(x, x >>> 17)
    x = bxor(x, x <<< 5 &&& @mask)
    x &&& @mask
  end

  @doc """
  Python の xorshift_shuffle(list(range(n)), seed) と同じ並びを
  %{位置 => 値} のマップで返す。scramble では dest = perm[i] として使う。
  """
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

  @doc """
  転置の別実装：タイルを目的地の順に並べ、Image.join（vips arrayjoin）で
  1回の演算にまとめてから原画の上に重ねる。compose を数百回連ねる方式は
  1VMで複数回実行すると終了時に segfault する再現があったため（SPIKE.md 参照）、
  演算グラフの深さを一定に保つこの方式を本命とする。
  """
  def scramble_join(image, seed, tile_size) do
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

  @doc "プラットフォームの scramble_image と同じ転置を行う（compose 連鎖版・比較用）"
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

      Enum.reduce(0..(n - 1), image, fn i, acc ->
        dest = Map.fetch!(perm, i)

        tile =
          Image.crop!(
            image,
            rem(i, cols) * tile_size,
            div(i, cols) * tile_size,
            tile_size,
            tile_size
          )

        Image.compose!(acc, tile,
          x: rem(dest, cols) * tile_size,
          y: div(dest, cols) * tile_size
        )
      end)
    end
  end
end
