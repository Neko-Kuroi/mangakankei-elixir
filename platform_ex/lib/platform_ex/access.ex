defmodule PlatformEx.Access do
  @moduledoc """
  アクセス制御の部屋：許可（grants）と管理者による公開停止（suspensions）、
  そして公開配信の前の執行判定。文言と順序は Python 版の _enforce_* と揃える。
  """
  import Ecto.Query

  alias PlatformEx.Access.{Grant, Suspension}
  alias PlatformEx.Accounts.User
  alias PlatformEx.Repo

  @doc "有効な公開停止（lifted_at が NULL）があればその行を返す（Python 版 _active_suspension と同じ）"
  def active_suspension(author_id, title_id) do
    Repo.one(
      from s in Suspension,
        where: s.author_id == ^author_id and s.title_id == ^title_id,
        where: is_nil(s.lifted_at),
        order_by: [asc: s.id],
        limit: 1
    )
  end

  @doc "作品への閲覧許可があるか"
  def has_grant?(author_id, title_id, user_id) do
    Repo.exists?(
      from g in Grant,
        where: g.author_id == ^author_id and g.title_id == ^title_id,
        where: g.user_id == ^user_id
    )
  end

  # ---------------------------------------------------------------------------
  # 執行判定（:ok か {:error, 状態コード, 文言} を返す）
  # ---------------------------------------------------------------------------

  @doc "公開停止の執行"
  def enforce_not_suspended(author_id, title_id) do
    if active_suspension(author_id, title_id) do
      {:error, 403, "この作品は公開が停止されています"}
    else
      :ok
    end
  end

  @doc """
  許可制エピソードの執行（Python 版 _enforce_premium_access）。
  reader は解決済みのユーザー（nil は匿名）。
  """
  def enforce_premium(meta, author_id, title_id, reader) do
    cond do
      meta["access_level"] != "premium" ->
        :ok

      is_nil(reader) ->
        {:error, 401, "この作品を読むにはログインが必要です"}

      reader.id == author_id ->
        :ok

      not has_grant?(author_id, title_id, reader.id) ->
        {:error, 403, "この作品を読む許可がありません"}

      truthy?(meta["age_restricted"]) && is_nil(reader.adult_declared_at) ->
        {:error, 403, "この作品を読むには年齢確認が必要です"}

      true ->
        :ok
    end
  end

  # Python の真値判定（キー欠け＝偽）に合わせる
  defp truthy?(value), do: value != nil and value != false

  @doc """
  年齢対象の無料作品の執行（Python 版 _enforce_age_access）。
  internal_age_verified は「内部通信＋ X-Age-Verified: 1」が揃ったとき true。
  """
  def enforce_age(meta, author_id, reader, internal_age_verified) do
    cond do
      not truthy?(meta["age_restricted"]) ->
        :ok

      meta["access_level"] == "premium" ->
        :ok

      not is_nil(reader) and (reader.id == author_id or not is_nil(reader.adult_declared_at)) ->
        :ok

      internal_age_verified ->
        :ok

      true ->
        {:error, 403, "年齢確認が必要です"}
    end
  end

  # ---------------------------------------------------------------------------
  # 許可（grants）
  # ---------------------------------------------------------------------------

  @doc "作品の許可一覧（created_at 順。ユーザーが消えている許可は除く）"
  def list_grants(author_id, title_id) do
    Repo.all(
      from g in Grant,
        join: u in User,
        on: u.id == g.user_id,
        where: g.author_id == ^author_id and g.title_id == ^title_id,
        order_by: [asc: g.created_at],
        select: %{
          user_id: u.id,
          username: u.username,
          created_at: g.created_at
        }
    )
  end

  @doc "ユーザー名で許可を与える（冪等。自分宛は 400、相手不在は 404）"
  def create_grant(author_id, title_id, username) do
    case Repo.get_by(User, username: username) do
      nil ->
        {:error, 404, "ユーザーが見つかりません"}

      %User{id: ^author_id} ->
        {:error, 400, "自分自身には許可できません"}

      %User{} = target ->
        if has_grant?(author_id, title_id, target.id) do
          {:ok, %{user_id: target.id, username: target.username, already: true}}
        else
          %Grant{}
          |> Ecto.Changeset.change(%{
            author_id: author_id,
            title_id: title_id,
            user_id: target.id,
            created_at: NaiveDateTime.utc_now(:microsecond)
          })
          |> Repo.insert!()

          {:ok, %{user_id: target.id, username: target.username, already: false}}
        end
    end
  end

  @doc "許可を取り消す"
  def delete_grant(author_id, title_id, user_id) do
    case Repo.get_by(Grant, author_id: author_id, title_id: title_id, user_id: user_id) do
      nil ->
        {:error, 404, "許可が見つかりません"}

      grant ->
        Repo.delete!(grant)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # 公開停止（管理者）
  # ---------------------------------------------------------------------------

  @doc "作品を公開停止にする（既に停止中なら already_suspended）"
  def suspend(admin, author_id, title_id, reason) do
    case active_suspension(author_id, title_id) do
      %Suspension{} = active ->
        {:ok, %{status: "already_suspended", reason: active.reason}}

      nil ->
        %Suspension{}
        |> Ecto.Changeset.change(%{
          author_id: author_id,
          title_id: title_id,
          reason: reason,
          suspended_by: admin.id,
          created_at: NaiveDateTime.utc_now(:microsecond)
        })
        |> Repo.insert!()

        {:ok, %{status: "suspended", reason: reason}}
    end
  end

  @doc "公開停止を解除する"
  def resume(author_id, title_id) do
    case active_suspension(author_id, title_id) do
      nil ->
        {:error, 404, "公開停止されていません"}

      %Suspension{} = active ->
        active
        |> Ecto.Changeset.change(%{lifted_at: NaiveDateTime.utc_now(:microsecond)})
        |> Repo.update!()

        {:ok, %{status: "resumed"}}
    end
  end
end
