defmodule PlatformExWeb.RateLimitKey do
  @moduledoc """
  レート制限のキー解決。Python 版 main.py の
  get_ip_for_limit / get_client_ip / _is_internal_request と同じ規則：

  - 内部リクエスト（localhost＋内部トークン一致）のときだけヘッダを信頼し、
    X-Viewer-Client-Key が64文字の16進ならそれをキーにする
  - それ以外は接続元IP。CF-Connecting-IP は MANGA_TRUST_CF_HEADER=1 のときだけ採用
  """
  import Plug.Conn

  @doc "内部リクエスト（同一マシン上の閲覧側など）かどうか"
  def internal?(conn) do
    token = System.get_env("MANGA_INTERNAL_TOKEN", "")

    token != "" and normalize_ip(conn.remote_ip) in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] and
      Plug.Crypto.secure_compare(first_header(conn, "x-internal-token"), token)
  end

  # IPv6 ワイルドカードで待ち受けると IPv4 の接続元が ::ffff:a.b.c.d の形で届く。
  # ループバック判定とキー文字列を IPv4 の形にそろえる（手順6で実測した不具合の修正）。
  defp normalize_ip({0, 0, 0, 0, 0, 65_535, hi, lo}) do
    {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}
  end

  defp normalize_ip(ip), do: ip

  @doc "制限キーに使うクライアントIP"
  def client_ip(conn) do
    if System.get_env("MANGA_TRUST_CF_HEADER") == "1" do
      case get_req_header(conn, "cf-connecting-ip") do
        [ip | _] when ip != "" -> ip
        _ -> remote_ip_string(conn)
      end
    else
      remote_ip_string(conn)
    end
  end

  @doc "レート制限のキー（閲覧側経由は viewer:<クライアントキー>）"
  def limit_key(conn) do
    if internal?(conn) do
      key = first_header(conn, "x-viewer-client-key")

      if Regex.match?(~r/\A[0-9a-f]{64}\z/, key) do
        "viewer:" <> key
      else
        client_ip(conn)
      end
    else
      client_ip(conn)
    end
  end

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> ""
    end
  end

  defp remote_ip_string(%Plug.Conn{remote_ip: nil}), do: "unknown"

  defp remote_ip_string(conn) do
    conn.remote_ip |> normalize_ip() |> :inet.ntoa() |> to_string()
  end
end
