defmodule PlatformEx.RateLimiter do
  @moduledoc """
  レート制限のカウンタ（Hammer、ETS バックエンド）。
  枠の意味論は slowapi（limits の固定ウィンドウ）と揃う。
  キーの組み立ては PlatformExWeb.RateLimitKey が担当する。
  """
  use Hammer, backend: :ets
end
