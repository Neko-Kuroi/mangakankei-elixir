defmodule YomimaEx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("VIEWER_PORT", "8001"))

    children = [
      YomimaEx.Store,
      YomimaEx.CatalogCache,
      {Bandit, plug: YomimaEx.Router, port: port, scheme: :http}
    ]

    opts = [strategy: :one_for_one, name: YomimaEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
