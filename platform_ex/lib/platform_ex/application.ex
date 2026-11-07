defmodule PlatformEx.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PlatformExWeb.Telemetry,
      PlatformEx.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:platform_ex, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:platform_ex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PlatformEx.PubSub},
      # レート制限のカウンタと、ログインのユーザー名単位カウンタ
      PlatformEx.RateLimiter,
      PlatformEx.LoginThrottle,
      # アップロード加工の土台（進捗ストア・同時実行の許可・作業タスクの監督・設定の錠前）
      PlatformEx.Jobs,
      PlatformEx.Jobs.Permits,
      {Task.Supervisor, name: PlatformEx.JobSupervisor},
      PlatformEx.SettingsLock,
      PlatformEx.ViewCounts,
      # 起動時に管理者アカウントの状況をログに出す（Python 版の起動時ログと同じ。
      # MANGA_ADMIN_USERS 未設定なら何もしない）
      {Task, &PlatformEx.BootCheck.run/0},
      # Start a worker by calling: PlatformEx.Worker.start_link(arg)
      # {PlatformEx.Worker, arg},
      # Start to serve requests, typically the last entry
      PlatformExWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PlatformEx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PlatformExWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
