defmodule PlatformEx.Access.Grant do
  @moduledoc """
  既存 grants テーブル（作品単位の閲覧許可）のスキーマ。
  author_id の作家が、title_id の作品を、user_id の読者に許可した記録。
  """
  use Ecto.Schema

  schema "grants" do
    field :author_id, :integer
    field :title_id, :integer
    field :user_id, :integer
    field :created_at, :naive_datetime_usec
  end
end
