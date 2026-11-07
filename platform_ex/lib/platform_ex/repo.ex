defmodule PlatformEx.Repo do
  use Ecto.Repo,
    otp_app: :platform_ex,
    adapter: Ecto.Adapters.SQLite3
end
