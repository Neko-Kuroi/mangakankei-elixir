defmodule PlatformSpike.Limiter do
  @moduledoc "手順0スパイク専用：Hammer（ETS）の意味論確認用リミッタ"
  use Hammer, backend: :ets
end
