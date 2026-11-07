defmodule PlatformEx.Access.Suspension do
  @moduledoc """
  既存 suspensions テーブル（管理者による公開停止）のスキーマ。
  lifted_at が NULL の行が「停止中」。作家の設定とは別に持ち、
  解除すると作家の設定がそのまま戻る（Python 版の設計と同じ）。
  """
  use Ecto.Schema

  schema "suspensions" do
    field :author_id, :integer
    field :title_id, :integer
    field :reason, :string
    field :suspended_by, :integer
    field :created_at, :naive_datetime_usec
    field :lifted_at, :naive_datetime_usec
  end
end
