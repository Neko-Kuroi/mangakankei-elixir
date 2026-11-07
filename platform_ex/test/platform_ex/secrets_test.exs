defmodule PlatformEx.SecretsTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias PlatformEx.Secrets

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "secrets_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    old = System.get_env("MANGA_SECRET_KEY")
    System.delete_env("MANGA_SECRET_KEY")

    on_exit(fn ->
      case old do
        nil -> System.delete_env("MANGA_SECRET_KEY")
        v -> System.put_env("MANGA_SECRET_KEY", v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  test "環境変数が最優先（前後の空白は除く）", %{dir: dir} do
    System.put_env("MANGA_SECRET_KEY", "  env-key  ")
    assert Secrets.load!(dir) == "env-key"
  end

  test "ファイルがあればそれを読む", %{dir: dir} do
    File.write!(Path.join(dir, "secret_key"), "file-key\n")
    assert Secrets.load!(dir) == "file-key"
  end

  test "どちらもなければ生成して 0600 で保存し、次回も同じ鍵を返す", %{dir: dir} do
    key = Secrets.load!(dir)
    assert String.length(key) == 64

    path = Path.join(dir, "secret_key")
    assert File.read!(path) == key
    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert Secrets.load!(dir) == key
  end

  test "空ファイルは RuntimeError（Python 版と同じ文言）", %{dir: dir} do
    File.write!(Path.join(dir, "secret_key"), "")

    assert_raise RuntimeError, ~r/が空です/, fn ->
      Secrets.load!(dir)
    end
  end
end
