defmodule PlatformEx.Accounts do
  @moduledoc """
  ユーザーの部屋：登録・認証・年齢申告・許可一覧。
  判定の順序と文言は Python 版 main.py の認証まわりと揃える。
  """
  import Ecto.Query

  alias PlatformEx.Accounts.User
  alias PlatformEx.Access.Grant
  alias PlatformEx.{Admin, Auth, LoginThrottle, Repo}

  # ---------------------------------------------------------------------------
  # ユーザー名の正規化と予約（管理者名の先取り対策。判定は予約専用で、
  # 管理者かどうかの判定には使わない）
  # ---------------------------------------------------------------------------

  @zero_width ["\u200B", "\u200C", "\u200D", "\uFEFF"]

  @doc """
  ユーザー名の表記ゆれを寄せる：NFKC、大文字小文字、前後の空白、
  ゼロ幅文字の有無だけを寄せ、文字そのものが違う名前は寄せない。
  Python 版 normalize_username と同じ（casefold の差分として
  ß→ss と ς→σ は String.downcase の後に補う）。
  """
  def normalize_username(name) when is_binary(name) do
    name
    |> :unicode.characters_to_nfkc_binary()
    |> String.replace(@zero_width, "")
    |> String.trim()
    |> String.downcase()
    |> String.replace("ß", "ss")
    |> String.replace("ς", "σ")
  end

  @doc "管理者名（と表記ゆれだけ違う名前）なら true。一般の登録には使えない"
  def reserved_username?(username) do
    target = normalize_username(username)
    Enum.any?(Admin.names(), fn n -> normalize_username(n) == target end)
  end

  # ---------------------------------------------------------------------------
  # パスワード
  # ---------------------------------------------------------------------------

  @doc "パスワードの共通規則。問題があれば利用者向けの文言、無ければ nil"
  def password_rule_error(password) when is_binary(password) do
    cond do
      length(String.codepoints(password)) < 8 ->
        "パスワードは8文字以上で入力してください"

      byte_size(password) > 72 ->
        "パスワードが長すぎます（72バイトまで）"

      true ->
        nil
    end
  end

  # Python 版と同じく、先頭72バイトで切り詰めてから bcrypt に渡す
  defp truncate72(password), do: binary_part(password, 0, min(byte_size(password), 72))

  def hash_password(password), do: Bcrypt.hash_pwd_salt(truncate72(password))

  def verify_password(password, hashed)
      when is_binary(password) and is_binary(hashed) do
    Bcrypt.verify_pass(truncate72(password), hashed)
  rescue
    _ -> false
  end

  def verify_password(_, _), do: false

  # ---------------------------------------------------------------------------
  # メールアドレス（pydantic の EmailStr の近似。厳密な検証規則は
  # email-validator 側にあるため、ここでは実用上必要な形だけを見る）
  # ---------------------------------------------------------------------------

  def valid_email?(email) when is_binary(email) do
    case String.split(email, "@") do
      [local, domain] ->
        local != "" and byte_size(local) <= 64 and byte_size(email) <= 254 and
          String.contains?(domain, ".") and
          not String.contains?(email, [" ", "\t", "\n"])

      _ ->
        false
    end
  end

  def valid_email?(_), do: false

  # ---------------------------------------------------------------------------
  # 登録
  # ---------------------------------------------------------------------------

  @doc """
  ユーザー登録。チェックの順序と文言は Python 版 signup と同じ：
  メール重複 → 予約名 → ユーザー名重複 → 種別 → パスワード規則。
  """
  def register_user(%{
        "username" => username,
        "email" => email,
        "password" => password,
        "account_type" => account_type
      }) do
    cond do
      get_user_by_email(email) != nil ->
        {:error, "登録済みのメールアドレスです"}

      reserved_username?(username) ->
        {:error, "使用済みのユーザー名です"}

      get_user_by_username(username) != nil ->
        {:error, "使用済みのユーザー名です"}

      account_type not in ["author", "reader"] ->
        {:error, "アカウント種別が不正です"}

      (msg = password_rule_error(password)) != nil ->
        {:error, msg}

      true ->
        %User{
          username: username,
          email: email,
          hashed_password: hash_password(password),
          account_type: account_type,
          is_active: true
        }
        |> Repo.insert()
    end
  end

  # ---------------------------------------------------------------------------
  # 認証
  # ---------------------------------------------------------------------------

  @doc """
  ログイン認証。ユーザー名カウンタによるブロック、失敗の記録、
  成功時のリセットまで Python 版 login と同じ流れ。
  """
  def authenticate(username, password) do
    if LoginThrottle.blocked?(username) do
      {:error, 429, "リクエストが多すぎます。しばらく待ってから再試行してください。"}
    else
      user = get_user_by_username(username)

      cond do
        user == nil or not verify_password(password, user && user.hashed_password) ->
          LoginThrottle.record_failure(username)
          {:error, 401, "ユーザー名またはパスワードが正しくありません"}

        not user.is_active ->
          LoginThrottle.record_failure(username)
          {:error, 401, "ユーザー名またはパスワードが正しくありません"}

        true ->
          LoginThrottle.clear(username)
          {:ok, user}
      end
    end
  end

  @doc """
  トークンからユーザーを引く（Python 版 user_from_token と同じ）。
  デコード失敗と、ユーザー不在・停止中は、文言の違う 401 になる。
  """
  def user_from_token(token) do
    case Auth.Token.verify(token) do
      {:ok, user_id} ->
        case get_user(user_id) do
          %User{is_active: true} = user -> {:ok, user}
          _ -> {:error, "ユーザーが見つかりません"}
        end

      :error ->
        {:error, "トークンが無効または期限切れです"}
    end
  end

  # ---------------------------------------------------------------------------
  # 年齢申告・許可一覧
  # ---------------------------------------------------------------------------

  @doc "年齢確認の自己申告を記録する（冪等・取り消し不可）"
  def declare_adult(%User{adult_declared_at: nil} = user) do
    user
    |> Ecto.Changeset.change(adult_declared_at: NaiveDateTime.utc_now(:microsecond))
    |> Repo.update()
  end

  def declare_adult(%User{} = user), do: {:ok, user}

  @doc "自分に許可が出ている作品（author_id, title_id）の一覧"
  def grants_for_user(%User{id: user_id}) do
    Repo.all(
      from g in Grant,
        where: g.user_id == ^user_id,
        select: %{author_id: g.author_id, title_id: g.title_id}
    )
  end

  # ---------------------------------------------------------------------------
  # 参照
  # ---------------------------------------------------------------------------

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_username(username),
    do: Repo.one(from u in User, where: u.username == ^username)

  def get_user_by_email(email),
    do: Repo.one(from u in User, where: u.email == ^email)
end
