defmodule PlatformEx.LegacySchema do
  @moduledoc """
  テスト用DBに、Python 版が作った既存テーブル（users/grants/suspensions）を
  本物と同じ定義で用意する。マイグレーションでは作らない方針のため、
  テストではここで用意する。
  """

  alias PlatformEx.Repo

  @ddl [
    """
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER NOT NULL PRIMARY KEY,
      username VARCHAR NOT NULL,
      email VARCHAR NOT NULL,
      hashed_password VARCHAR NOT NULL,
      is_active BOOLEAN,
      account_type VARCHAR,
      adult_declared_at DATETIME
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS grants (
      id INTEGER NOT NULL PRIMARY KEY,
      author_id INTEGER NOT NULL,
      title_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      created_at DATETIME,
      UNIQUE (author_id, title_id, user_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS suspensions (
      id INTEGER NOT NULL PRIMARY KEY,
      author_id INTEGER NOT NULL,
      title_id INTEGER NOT NULL,
      reason VARCHAR,
      suspended_by INTEGER NOT NULL,
      created_at DATETIME,
      lifted_at DATETIME
    )
    """
  ]

  def setup! do
    Enum.each(@ddl, fn sql ->
      Ecto.Adapters.SQL.query!(Repo, sql, [])
    end)

    :ok
  end
end
