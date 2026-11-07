defmodule PlatformEx.Jobs.Job do
  @moduledoc """
  加工ジョブの状態を持つテーブル（この実装で新設する唯一のテーブル）。
  アップロード後の加工（リサイズ→スクランブル→CBZ 化→サムネイル）を
  作業プロセスに渡し、状態を queued → running → done / failed で追う。
  work_key は対象を指す文字列（例: "user_1/title_2/episode_3"）。
  """
  use Ecto.Schema

  schema "jobs" do
    field :status, :string, default: "queued"
    field :work_key, :string
    field :error, :string

    timestamps(type: :utc_datetime)
  end
end
