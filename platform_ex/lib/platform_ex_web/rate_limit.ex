defmodule PlatformExWeb.RateLimit do
  @moduledoc """
  レート制限の確認。FastAPI では slowapi の確認が「入力検証の後・
  ハンドラ本体の前」に入るため、プラグではなくアクション内の
  正確な位置から呼べるよう関数にしている。
  超過時は Python 版の RateLimitExceeded ハンドラと同じ
  429＋テキスト文言で応答して halt する。
  """
  import Plug.Conn

  alias PlatformEx.RateLimiter
  alias PlatformExWeb.RateLimitKey

  @message "リクエストが多すぎます。しばらく待ってから再試行してください。"

  @doc """
  枠に空きがあれば :ok、超過していれば {:error, 応答済みconn} を返す。
  bucket は制限の種類（"signup" / "login" など）、scale_ms は窓の長さ、limit は回数。
  """
  def check(conn, bucket, scale_ms, limit) do
    key = "#{bucket}:#{RateLimitKey.limit_key(conn)}"

    case RateLimiter.hit(key, scale_ms, limit) do
      {:allow, _count} ->
        :ok

      {:deny, _limit} ->
        conn =
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(429, @message)
          |> halt()

        {:error, conn}
    end
  end

  @doc "内部リクエスト（閲覧側の代表取得）は数えない版（slowapi の exempt_when と同じ）"
  def check_unless_internal(conn, bucket, scale_ms, limit) do
    if RateLimitKey.internal?(conn) do
      :ok
    else
      check(conn, bucket, scale_ms, limit)
    end
  end

  @doc "応答は送らず、枠に空きがあるかだけを返す（画面のフォーム送信用）"
  def allowed?(conn, bucket, scale_ms, limit) do
    key = "#{bucket}:#{RateLimitKey.limit_key(conn)}"

    case RateLimiter.hit(key, scale_ms, limit) do
      {:allow, _count} -> true
      {:deny, _limit} -> false
    end
  end
end
