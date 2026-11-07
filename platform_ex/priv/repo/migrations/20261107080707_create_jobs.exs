defmodule PlatformEx.Repo.Migrations.CreateJobs do
  use Ecto.Migration

  # 既存テーブル（users/grants/suspensions）は Python 版が作ったものなので
  # マイグレーションでは作らない。この実装で増やすのは jobs だけ。
  def change do
    create table(:jobs) do
      add :status, :string, null: false, default: "queued"
      add :work_key, :string, null: false
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:jobs, [:status])
  end
end
