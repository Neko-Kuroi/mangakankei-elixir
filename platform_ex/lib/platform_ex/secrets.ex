defmodule PlatformEx.Secrets do
  @moduledoc """
  JWT 署名鍵の解決。Python 版 main.py の _load_secret_key と同じ順序・同じ流儀：

  1. 環境変数 MANGA_SECRET_KEY（前後の空白を除いて非空なら）
  2. instance/secret_key ファイル
  3. どちらもなければ生成してファイルへ保存（権限 0600、
     一時ファイルに書き切ってから link で公開するので、公開時点で常に完成済み）

  空のファイルはエラーにする（Python 版の RuntimeError と同じ文言・同じ扱い）。
  """

  @doc "署名鍵を解決する（解決結果はプロセス内でキャッシュする）"
  def jwt_secret do
    case :persistent_term.get({__MODULE__, :jwt_secret}, :unset) do
      :unset ->
        secret = load!(instance_dir())
        :persistent_term.put({__MODULE__, :jwt_secret}, secret)
        secret

      secret ->
        secret
    end
  end

  @doc "instance ディレクトリ（カレント相対。アプリ設定 :instance_dir で差し替え可能）"
  def instance_dir do
    Application.get_env(
      :platform_ex,
      :instance_dir,
      Path.join(File.cwd!(), "instance")
    )
  end

  @doc "鍵を解決する本体（テストから直接呼べるよう instance ディレクトリを引数に取る）"
  def load!(dir) do
    case System.get_env("MANGA_SECRET_KEY", "") |> String.trim() do
      "" -> from_file(dir)
      key -> key
    end
  end

  defp from_file(dir) do
    path = Path.join(dir, "secret_key")

    unless File.exists?(path) do
      File.mkdir_p!(dir)
      publish_new_key(path, dir)
    end

    key = path |> File.read!() |> String.trim()

    if key == "" do
      raise RuntimeError,
            "#{path} が空です。削除して再起動するか MANGA_SECRET_KEY を設定してください"
    end

    key
  end

  # Python 版は secrets.token_urlsafe(48)（48バイト→base64url 64文字）を
  # mkstemp（0600）で書いて os.link で公開し、先着の鍵を使う。
  defp publish_new_key(path, dir) do
    secret = :crypto.strong_rand_bytes(48) |> Base.url_encode64(padding: false)
    tmp = Path.join(dir, ".secret_key.#{:erlang.unique_integer([:positive])}")

    File.write!(tmp, secret)
    File.chmod!(tmp, 0o600)

    case File.ln(tmp, path) do
      :ok -> :ok
      # 先着の鍵を使う
      {:error, :eexist} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "link", path: path
    end

    File.rm(tmp)
    :ok
  end
end
