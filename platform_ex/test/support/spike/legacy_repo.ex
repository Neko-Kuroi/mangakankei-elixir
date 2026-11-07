defmodule PlatformSpike.LegacyRepo do
  @moduledoc "手順0スパイク専用：既存の manga_platform.db を開くための Repo"
  use Ecto.Repo,
    otp_app: :platform_ex,
    adapter: Ecto.Adapters.SQLite3
end
