defmodule PlatformEx.Release do
  @moduledoc """
  release 運用時のマイグレーション実行（既存 DB への jobs テーブル追加）。

      bin/platform_ex eval "PlatformEx.Release.migrate()"
  """

  @app :platform_ex

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)

    # SSL を使う依存（マイグレーション自体には不要だが、起動に必要な場合がある）
    Application.ensure_all_started(:ssl)
  end
end
