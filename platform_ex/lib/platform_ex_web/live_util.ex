defmodule PlatformExWeb.LiveUtil do
  @moduledoc "LiveView 共通の小さな道具"

  @doc """
  このリクエストの base_url（Python 版の request.base_url 相当。
  既定ポートのときはポートを省く）。
  """
  def base_url(socket) do
    uri = socket.host_uri
    host = uri.host || "localhost"
    scheme = uri.scheme || "http"

    if uri.port in [nil, 80, 443] do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{uri.port}"
    end
  end
end
