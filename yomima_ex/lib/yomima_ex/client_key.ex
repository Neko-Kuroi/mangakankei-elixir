defmodule YomimaEx.ClientKey do
  @moduledoc """
  クライアントキー（プラットフォームのレート制限を読者ごとに分ける）。
  Python 版 yomima/main.py の _client_key_secret / _client_key_for と同じ仕様:

  - 閲覧側は読者の実IPから HMAC-SHA256(秘密, IP) の hex（64文字）を計算し、
    プラットフォームへのログイン・登録の代理送信に X-Viewer-Client-Key
    ヘッダとして付ける。生IPはプラットフォームに送らない。
  - 秘密は閲覧側だけが持つ。解決順: 環境変数 MANGA_CLIENT_KEY_SECRET ＞
    instance/client_key_secret ファイル ＞ 初回に生成して同ファイルへ
    保存（0600、原子的に公開）。プラットフォームには配布しない。
  - 秘密が用意できない異常時は空文字になり、その場合はキー自体を付けない
    （プラットフォーム側は従来どおり閲覧側IPで数える）。
  秘密のキャッシュは Store が持つ（解決は初回だけ、失敗した場合の
  空文字も含めてプロセスの間は固定）。
  """

  alias YomimaEx.Store

  @doc """
  秘密ファイルのパス。Python 版は閲覧側コードの隣の instance/ を使う。
  Elixir 版は起動時のカレントディレクトリ配下の instance/ を既定とし、
  テスト等では Application env :client_key_secret_file で差し替えられる。
  手順6（mix release の配布確認）で再検討した結果、cwd 相対を維持する:
  release を別 cwd から起動して instance/client_key_secret が 0600 で
  生成されることを実測済みで、運用では起動ディレクトリを固定すれば
  足りる。明示したい場合は環境変数 MANGA_CLIENT_KEY_SECRET が優先
  される（秘密が変わるとレート制限の枠は数え直しになる）。
  """
  def secret_file do
    Application.get_env(:yomima_ex, :client_key_secret_file) ||
      Path.join([File.cwd!(), "instance", "client_key_secret"])
  end

  @doc "秘密を解決する（キャッシュしない素の解決。Store 経由が通常経路）。"
  def resolve_secret do
    case System.get_env("MANGA_CLIENT_KEY_SECRET", "") do
      "" -> from_file_or_generate()
      env -> env
    end
  end

  defp from_file_or_generate do
    path = secret_file()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, value} -> String.trim(value)
        {:error, _} -> ""
      end
    else
      generate_and_store(path)
    end
  end

  defp generate_and_store(path) do
    value = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.mkdir_p!(Path.dirname(path))
      File.write!(tmp, value)
      File.chmod!(tmp, 0o600)
      File.rename!(tmp, path)
      value
    rescue
      _ ->
        File.rm(tmp)
        ""
    end
  end

  @doc "キャッシュ付きの秘密（Store に保持）。空文字は「キーなし」を意味する。"
  def secret, do: Store.client_key_secret()

  @doc "IP 文字列からクライアントキーを計算する。秘密が無ければ空文字。"
  def key_for_ip(ip) do
    case secret() do
      "" ->
        ""

      sec ->
        :crypto.mac(:hmac, :sha256, sec, ip)
        |> Base.encode16(case: :lower)
    end
  end

  @doc """
  読者の実IP（Python 版 get_client_ip と同じ規則）。
  原則は接続元アドレス。CF-Connecting-IP は環境変数
  MANGA_TRUST_CF_HEADER=1 のときだけ採用する。
  """
  def client_ip(conn) do
    cf =
      if System.get_env("MANGA_TRUST_CF_HEADER") == "1" do
        conn |> Plug.Conn.get_req_header("cf-connecting-ip") |> List.first()
      end

    cond do
      is_binary(cf) and cf != "" ->
        cf

      conn.remote_ip ->
        conn.remote_ip |> :inet.ntoa() |> to_string()

      true ->
        "unknown"
    end
  end

  @doc "このリクエストのクライアントキー（無ければ空文字）。"
  def key_for_conn(conn), do: conn |> client_ip() |> key_for_ip()
end
