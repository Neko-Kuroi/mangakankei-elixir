defmodule PlatformExWeb.RateLimitKeyTest do
  use ExUnit.Case, async: false

  alias PlatformExWeb.RateLimitKey

  @key String.duplicate("a", 64)

  setup do
    old_cf = System.get_env("MANGA_TRUST_CF_HEADER")
    System.delete_env("MANGA_TRUST_CF_HEADER")

    on_exit(fn ->
      case old_cf do
        nil -> System.delete_env("MANGA_TRUST_CF_HEADER")
        v -> System.put_env("MANGA_TRUST_CF_HEADER", v)
      end
    end)

    :ok
  end

  defp conn(remote_ip, headers \\ []) do
    c = Plug.Test.conn(:get, "/")
    c = %{c | remote_ip: remote_ip}

    Enum.reduce(headers, c, fn {k, v}, acc ->
      Plug.Conn.put_req_header(acc, k, v)
    end)
  end

  test "内部判定：localhost＋トークン一致のときだけ" do
    assert RateLimitKey.internal?(
             conn({127, 0, 0, 1}, [{"x-internal-token", "test-internal-token"}])
           )

    assert RateLimitKey.internal?(
             conn({0, 0, 0, 0, 0, 0, 0, 1}, [{"x-internal-token", "test-internal-token"}])
           )

    refute RateLimitKey.internal?(conn({127, 0, 0, 1}, [{"x-internal-token", "wrong"}]))

    refute RateLimitKey.internal?(
             conn({10, 0, 0, 5}, [{"x-internal-token", "test-internal-token"}])
           )

    refute RateLimitKey.internal?(conn({127, 0, 0, 1}))
  end

  test "キー解決：内部＋64桁16進キーなら viewer: キー、それ以外は IP" do
    internal = [{"x-internal-token", "test-internal-token"}]

    assert RateLimitKey.limit_key(
             conn({127, 0, 0, 1}, internal ++ [{"x-viewer-client-key", @key}])
           ) == "viewer:#{@key}"

    # キーの形が違う場合は IP に落ちる
    assert RateLimitKey.limit_key(
             conn({127, 0, 0, 1}, internal ++ [{"x-viewer-client-key", "XYZ"}])
           ) == "127.0.0.1"

    # 内部でなければヘッダは無視される
    assert RateLimitKey.limit_key(conn({127, 0, 0, 1}, [{"x-viewer-client-key", @key}])) ==
             "127.0.0.1"
  end

  test "IPv4 マップド IPv6（::ffff:127.0.0.1）でも内部判定とキーが IPv4 と揃う" do
    internal = [{"x-internal-token", "test-internal-token"}]
    mapped = {0, 0, 0, 0, 0, 65_535, 32_512, 1}

    assert RateLimitKey.internal?(conn(mapped, internal))
    assert RateLimitKey.client_ip(conn(mapped, [])) == "127.0.0.1"

    assert RateLimitKey.limit_key(conn(mapped, internal ++ [{"x-viewer-client-key", @key}])) ==
             "viewer:#{@key}"

    # ループバックでないマップド形式（::ffff:10.0.0.5）は内部にならない
    refute RateLimitKey.internal?(conn({0, 0, 0, 0, 0, 65_535, 2_560, 5}, internal))
    assert RateLimitKey.client_ip(conn({0, 0, 0, 0, 0, 65_535, 2_560, 5}, [])) == "10.0.0.5"
  end

  test "CF ヘッダは MANGA_TRUST_CF_HEADER=1 のときだけ採用する" do
    c = conn({10, 0, 0, 5}, [{"cf-connecting-ip", "203.0.113.9"}])
    assert RateLimitKey.client_ip(c) == "10.0.0.5"

    System.put_env("MANGA_TRUST_CF_HEADER", "1")
    assert RateLimitKey.client_ip(c) == "203.0.113.9"
  end
end
