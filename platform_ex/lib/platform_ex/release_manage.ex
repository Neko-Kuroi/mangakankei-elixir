defmodule PlatformEx.ReleaseManage do
  @moduledoc """
  release 版の管理コマンド（mix manage の代替）。引数の形は mix manage と同じ。
  パスワードは環境変数名で渡す（Python 版 manage.py の --password-env と同じ）。

      bin/platform_ex eval 'PlatformEx.ReleaseManage.run(["list-admins"])'
      ADMIN_PW=... bin/platform_ex eval 'PlatformEx.ReleaseManage.run(["create-admin", "boss", "--email", "boss@example.com", "--password-env", "ADMIN_PW"])'
  """

  alias PlatformEx.Manage

  def run(argv) do
    # eval の標準出力は既定で latin1 扱いになり日本語がエスケープされるため unicode に寄せる
    :io.setopts(:standard_io, encoding: :unicode)
    IO.puts("対象DB: #{db_path()}")

    # eval ではアプリが起動していないため、Repo だけを一時的に起動して使う
    {:ok, _, _} =
      Ecto.Migrator.with_repo(PlatformEx.Repo, fn _repo ->
        case argv do
          ["list-admins"] ->
            Enum.each(Manage.list_admins(), &IO.puts/1)

          ["create-admin", username | rest] ->
            create_admin(username, rest)

          _ ->
            IO.puts(
              "使い方: run([\"list-admins\"]) | run([\"create-admin\", USERNAME, \"--email\", X, \"--password-env\", VAR, (\"--reset\")])"
            )
        end
      end)

    :ok
  end

  defp create_admin(username, args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [email: :string, password_env: :string, reset: :boolean, type: :string]
      )

    with {:ok, password} <- password_from(opts[:password_env]),
         {:ok, message} <-
           Manage.create_admin(username, opts[:email], password,
             reset: opts[:reset] || false,
             account_type: opts[:type]
           ) do
      IO.puts(message)
    else
      {:error, message} -> IO.puts("エラー: #{message}")
    end
  end

  defp password_from(nil), do: {:error, "パスワードは --password-env で渡してください"}

  defp password_from(var) do
    case System.get_env(var, "") do
      "" -> {:error, "環境変数 #{var} が空か未設定です"}
      value -> {:ok, value}
    end
  end

  defp db_path do
    :platform_ex
    |> Application.get_env(PlatformEx.Repo, [])
    |> Keyword.get(:database, "")
    |> Path.expand()
  end
end
