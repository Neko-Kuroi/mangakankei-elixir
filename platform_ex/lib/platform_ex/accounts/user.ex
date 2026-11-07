defmodule PlatformEx.Accounts.User do
  @moduledoc """
  既存 users テーブル（Python 版が作ったもの）のスキーマ。
  列の意味は Python 版 main.py の User モデルと同じ。
  """
  use Ecto.Schema

  schema "users" do
    field :username, :string
    field :email, :string
    field :hashed_password, :string
    field :is_active, :boolean, default: true
    # "author" | "reader"（アクセス制御の段階1で追加された列）
    field :account_type, :string, default: "author"
    field :adult_declared_at, :naive_datetime_usec
  end
end
