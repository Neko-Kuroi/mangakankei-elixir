defmodule PlatformEx.Admin do
  @moduledoc """
  管理者の判定と状態確認。管理者は環境変数 MANGA_ADMIN_USERS の
  ユーザー名（カンマ区切り）で決まり、判定は完全一致
  （Python 版 main.py の is_admin / admin_names と同じ）。
  環境変数は都度読む（Python 版と同じ）。
  """
  import Ecto.Query

  alias PlatformEx.Accounts.User
  alias PlatformEx.Repo

  @doc "管理者のユーザー名リスト（前後空白を除き、空要素を捨て、重複を除く）"
  def names do
    System.get_env("MANGA_ADMIN_USERS", "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc "管理者かどうか（完全一致）"
  def admin?(username), do: username in names()

  @doc """
  管理者名ごとのアカウント状況を、名前順に
  [{name, :missing | {:registered, email}}] で返す（起動時ログ用）。
  """
  def status_report do
    names()
    |> Enum.sort()
    |> Enum.map(fn name ->
      case Repo.one(from u in User, where: u.username == ^name, select: u.email) do
        nil -> {name, :missing}
        email -> {name, {:registered, email}}
      end
    end)
  end
end
