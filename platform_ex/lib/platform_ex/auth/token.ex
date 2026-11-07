defmodule PlatformEx.Auth.Token do
  @moduledoc """
  JWT（HS256、60分）の発行と検証。Python 版（python-jose）と同じ契約：
  ペイロードは {sub: ユーザーIDの文字列, exp} のみ。
  署名鍵は PlatformEx.Secrets が解決する。
  """

  @expire_seconds 3600

  defp signer, do: Joken.Signer.create("HS256", PlatformEx.Secrets.jwt_secret())

  @doc "ユーザーIDからトークンを発行する"
  def issue(user_id) do
    exp =
      DateTime.utc_now() |> DateTime.add(@expire_seconds, :second) |> DateTime.to_unix()

    {:ok, token, _claims} =
      Joken.encode_and_sign(%{"sub" => Integer.to_string(user_id), "exp" => exp}, signer())

    token
  end

  @doc "トークンを検証してユーザーIDを返す。失敗は :error（理由は区別しない）"
  def verify(token) when is_binary(token) do
    with {:ok, claims} <- Joken.verify(token, signer()),
         sub when is_binary(sub) <- claims["sub"],
         {user_id, ""} <- Integer.parse(sub) do
      {:ok, user_id}
    else
      _ -> :error
    end
  end

  def verify(_), do: :error
end
