defmodule PlatformSpike.LegacyUser do
  @moduledoc "手順0スパイク専用：既存 users テーブルの読み取りスキーマ"
  use Ecto.Schema

  schema "users" do
    field :username, :string
    field :email, :string
    field :hashed_password, :string
    field :is_active, :boolean
    field :account_type, :string
    field :adult_declared_at, :string
  end
end
