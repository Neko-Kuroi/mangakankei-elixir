defmodule PlatformEx.Manage do
  @moduledoc """
  運用コマンドの本体（Python 版 manage.py と同じ振る舞い・文言）。
  管理者アカウントの作成・置き換えと、管理者名ごとの状態表示を行う。
  呼び出し側は Mix.Tasks.Manage（手順6で release 用の入口もここに寄せる）。
  """
  alias PlatformEx.{Accounts, Admin}
  alias PlatformEx.Accounts.User
  alias PlatformEx.Repo

  @doc """
  管理者アカウントを作る。opts: reset: boolean, account_type: "author" | "reader" | nil。
  戻り値は {:ok, 利用者向け文言} | {:error, 利用者向け文言}。
  """
  def create_admin(username, email, password, opts \\ []) do
    reset = Keyword.get(opts, :reset, false)
    account_type = Keyword.get(opts, :account_type)

    cond do
      username not in Admin.names() ->
        {:error,
         "'#{username}' は MANGA_ADMIN_USERS に含まれていません。" <>
           "サーバーと同じ値を環境変数に設定してから実行してください。"}

      account_type not in [nil, "author", "reader"] ->
        {:error, "--type は author か reader を指定してください"}

      (msg = Accounts.password_rule_error(password)) != nil ->
        {:error, msg}

      email != nil and not Accounts.valid_email?(email) ->
        {:error, "メールアドレスが不正です: #{email_reason(email)}"}

      true ->
        do_create_admin(username, email, password, reset, account_type)
    end
  end

  defp do_create_admin(username, email, password, reset, account_type) do
    case Accounts.get_user_by_username(username) do
      nil -> create_new(username, email, password, account_type)
      user -> maybe_reset(user, email, password, reset, account_type)
    end
  end

  defp create_new(_username, nil, _password, _account_type) do
    {:error, "新規作成には --email が必要です"}
  end

  defp create_new(username, email, password, account_type) do
    case Accounts.get_user_by_email(email) do
      %User{} = holder ->
        {:error, "メールアドレス #{email} は '#{holder.username}' が使用中です"}

      nil ->
        type = account_type || "author"

        %User{
          username: username,
          email: email,
          hashed_password: Accounts.hash_password(password),
          account_type: type,
          is_active: true
        }
        |> Repo.insert()
        |> case do
          {:ok, _user} ->
            {:ok, "管理者アカウントを作成しました: #{username}（email=#{email}, 種別=#{type}）"}

          {:error, changeset} ->
            {:error, "作成に失敗しました: #{inspect(changeset.errors)}"}
        end
    end
  end

  defp maybe_reset(user, _email, _password, false, _account_type) do
    {:error,
     "'#{user.username}' は既に登録されています（email=#{user.email}）。" <>
       "自分のアカウントなら、そのまま管理者として使えます。" <>
       "見覚えのないメールなら、--reset でパスワードとメールを置き換えてください。"}
  end

  defp maybe_reset(user, email, password, true, account_type) do
    holder =
      if email != nil and email != user.email do
        case Accounts.get_user_by_email(email) do
          %User{id: id} = holder when id != user.id -> holder
          _ -> nil
        end
      end

    if holder do
      {:error, "メールアドレス #{email} は '#{holder.username}' が使用中です"}
    else
      changes =
        %{
          hashed_password: Accounts.hash_password(password),
          is_active: true
        }
        |> maybe_put(:email, email)
        |> maybe_put(:account_type, account_type)

      user
      |> Ecto.Changeset.change(changes)
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          {:ok,
           "管理者アカウントを更新しました: #{updated.username}" <>
             "（email=#{updated.email}, 種別=#{updated.account_type}）"}

        {:error, changeset} ->
          {:error, "更新に失敗しました: #{inspect(changeset.errors)}"}
      end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "MANGA_ADMIN_USERS の各名前について、アカウントの状況を1行ずつ返す"
  def list_admins do
    case Admin.names() |> Enum.sort() do
      [] ->
        ["MANGA_ADMIN_USERS が設定されていません（管理者はいません）"]

      names ->
        Enum.map(names, fn name ->
          case Accounts.get_user_by_username(name) do
            nil ->
              "#{name}: アカウントなし"

            user ->
              "#{name}: 登録済み（id=#{user.id}, email=#{user.email}, " <>
                "種別=#{user.account_type || "author"}, 有効=#{if user.is_active, do: "True", else: "False"}）"
          end
        end)
    end
  end

  # email-validator の理由文のうち代表的なもの（Accounts の検証と同じ寄せ方）
  defp email_reason(email) do
    if String.contains?(email, "@") do
      "The email address is not valid."
    else
      "An email address must have an @-sign."
    end
  end
end
