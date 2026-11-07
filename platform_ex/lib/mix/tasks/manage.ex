defmodule Mix.Tasks.Manage do
  @shortdoc "管理者アカウントの作成・確認（Python 版 manage.py 相当）"
  @moduledoc """
  運用コマンド。

      mix manage list-admins
      mix manage create-admin boss --email boss@example.com --password-env ADMIN_PW
      mix manage create-admin boss --email new@example.com --password-env ADMIN_PW --reset

  対象DB（アプリ設定の manga_platform.db）を実行時に絶対パスで表示する。
  パスワードは引数に直接渡さない（履歴・プロセス一覧に残るため）。
  Python 版の対話入力（getpass）相当は無いので、--password-env が必須。
  """

  use Mix.Task

  @doc false
  def run(args) do
    Mix.Task.run("app.start")
    IO.puts("対象DB: #{db_path()}")

    case args do
      ["list-admins"] ->
        Enum.each(PlatformEx.Manage.list_admins(), &IO.puts/1)

      ["create-admin", username | rest] ->
        create_admin(username, rest)

      _ ->
        fail(
          "使い方: mix manage list-admins | mix manage create-admin USERNAME --email X --password-env VAR [--reset] [--type author|reader]"
        )
    end
  end

  defp create_admin(username, args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [email: :string, password_env: :string, reset: :boolean, type: :string]
      )

    password =
      case opts[:password_env] do
        nil ->
          fail("パスワードは --password-env で渡してください")

        var ->
          case System.get_env(var, "") do
            "" -> fail("環境変数 #{var} が空か未設定です")
            value -> value
          end
      end

    PlatformEx.Manage.create_admin(username, opts[:email], password,
      reset: opts[:reset] || false,
      account_type: opts[:type]
    )
    |> report()
  end

  defp report({:ok, message}) do
    IO.puts(message)
  end

  defp report({:error, message}) do
    fail(message)
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  defp db_path do
    :platform_ex
    |> Application.get_env(PlatformEx.Repo, [])
    |> Keyword.get(:database, "")
    |> Path.expand()
  end
end
