defmodule YomimaEx.ClientKeyTest do
  use ExUnit.Case, async: false

  alias YomimaEx.{ClientKey, Platform, Store}

  # Python 版 (hmac.new(b"unit-test-secret", b"203.0.113.7", sha256)) と同じ値。
  # 実装間一致の検証ベクトルとして Python 側で計算した値を埋め込む。
  @expected_key "c42a60f3e82e343b843a5877db03932e9acb48f67aa5d9050643db6416c6bcf4"

  setup do
    saved =
      for var <- ["MANGA_CLIENT_KEY_SECRET", "MANGA_TRUST_CF_HEADER", "MANGA_INTERNAL_TOKEN"] do
        {var, System.get_env(var)}
      end

    saved_app_env = Application.get_env(:yomima_ex, :client_key_secret_file)
    Store.reset_client_key_secret()

    on_exit(fn ->
      for {var, value} <- saved do
        if value, do: System.put_env(var, value), else: System.delete_env(var)
      end

      if saved_app_env do
        Application.put_env(:yomima_ex, :client_key_secret_file, saved_app_env)
      else
        Application.delete_env(:yomima_ex, :client_key_secret_file)
      end

      Store.reset_client_key_secret()
    end)

    :ok
  end

  defp conn_with_ip(ip, headers \\ []) do
    conn = Plug.Test.conn(:post, "/auth/login")

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

    %{conn | remote_ip: ip}
  end

  test "client key is HMAC-SHA256 of the IP (Python と同じベクトル)" do
    System.put_env("MANGA_CLIENT_KEY_SECRET", "unit-test-secret")
    assert ClientKey.key_for_ip("203.0.113.7") == @expected_key
  end

  test "CF-Connecting-IP は MANGA_TRUST_CF_HEADER=1 のときだけ採用する" do
    System.put_env("MANGA_CLIENT_KEY_SECRET", "unit-test-secret")
    conn = conn_with_ip({10, 0, 0, 1}, [{"cf-connecting-ip", "198.51.100.9"}])

    # 信用しない場合は接続元IPから計算する
    System.delete_env("MANGA_TRUST_CF_HEADER")
    expected_direct = :crypto.mac(:hmac, :sha256, "unit-test-secret", "10.0.0.1") |> Base.encode16(case: :lower)
    assert ClientKey.key_for_conn(conn) == expected_direct

    # 信用する場合は CF の IP から計算する
    System.put_env("MANGA_TRUST_CF_HEADER", "1")
    expected_cf = :crypto.mac(:hmac, :sha256, "unit-test-secret", "198.51.100.9") |> Base.encode16(case: :lower)
    assert ClientKey.key_for_conn(conn) == expected_cf
  end

  test "auth_headers は内部トークンとクライアントキーを両方含む" do
    System.put_env("MANGA_CLIENT_KEY_SECRET", "unit-test-secret")
    System.put_env("MANGA_INTERNAL_TOKEN", "ck-test-token")
    conn = conn_with_ip({203, 0, 113, 7})
    headers = Platform.auth_headers(conn)
    assert {"x-internal-token", "ck-test-token"} in headers
    assert {"x-viewer-client-key", @expected_key} in headers
  end

  test "秘密ファイルが無ければ生成して 0600 で保存し、次回は同じ値を返す" do
    System.delete_env("MANGA_CLIENT_KEY_SECRET")
    dir = Path.join(System.tmp_dir!(), "ck_test_#{System.unique_integer([:positive])}")
    target = Path.join([dir, "instance", "client_key_secret"])
    Application.put_env(:yomima_ex, :client_key_secret_file, target)

    value = ClientKey.secret()
    assert Regex.match?(~r/^[0-9a-f]{64}$/, value)
    assert File.read!(target) |> String.trim() == value
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o600

    # キャッシュを落としても、ファイルの値が返る（再生成しない）
    Store.reset_client_key_secret()
    assert ClientKey.secret() == value

    File.rm_rf!(dir)
  end

  test "環境変数の秘密がファイルより優先される" do
    dir = Path.join(System.tmp_dir!(), "ck_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    target = Path.join(dir, "client_key_secret")
    File.write!(target, "file-value")
    Application.put_env(:yomima_ex, :client_key_secret_file, target)
    System.put_env("MANGA_CLIENT_KEY_SECRET", "env-value")

    assert ClientKey.secret() == "env-value"

    File.rm_rf!(dir)
  end
end
