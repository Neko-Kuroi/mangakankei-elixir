defmodule PlatformExWeb.UserAuth do
  @moduledoc """
  画面（LiveView）用の認証。ログインで発行した JWT をセッションに持ち、
  on_mount でユーザーに戻す（API の Bearer 認証と同じトークンを使う）。
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [redirect: 2, put_flash: 3]

  alias PlatformEx.Accounts
  alias PlatformEx.Admin

  @doc "セッションのトークンからユーザーを引いて assign する（いなくてもよい）"
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, base_assigns(socket, session, user_from_session(session))}
  end

  # ログイン必須。いなければ /login へ
  def on_mount(:require_user, _params, session, socket) do
    case user_from_session(session) do
      nil ->
        {:halt,
         socket
         |> put_flash(:error, "ログインが必要です")
         |> redirect(to: "/login")}

      user ->
        {:cont, base_assigns(socket, session, user)}
    end
  end

  # 管理者必須
  def on_mount(:require_admin, _params, session, socket) do
    case user_from_session(session) do
      nil ->
        {:halt,
         socket
         |> put_flash(:error, "ログインが必要です")
         |> redirect(to: "/login")}

      user ->
        if Admin.admin?(user.username) do
          {:cont, base_assigns(socket, session, user)}
        else
          {:halt,
           socket
           |> put_flash(:error, "管理者権限が必要です")
           |> redirect(to: "/")}
        end
    end
  end

  defp base_assigns(socket, session, user) do
    assign(socket,
      current_user: user,
      user_token: session["user_token"],
      viewer_url: session["viewer_url"] || ""
    )
  end

  defp user_from_session(session) do
    case session["user_token"] do
      token when is_binary(token) ->
        case Accounts.user_from_token(token) do
          {:ok, user} -> user
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
