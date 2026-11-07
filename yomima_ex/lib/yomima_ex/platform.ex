defmodule YomimaEx.Platform do
  @moduledoc """
  Python プラットフォームへの HTTP クライアント（無改造のプラットフォームと通信する）。
  カタログは60秒キャッシュ（CatalogCache GenServer）。
  """

  def base_url,
    do: System.get_env("PLATFORM_BASE_URL", "http://localhost:8000") |> String.trim_trailing("/")

  def internal_headers do
    case System.get_env("MANGA_INTERNAL_TOKEN", "") do
      "" -> []
      token -> [{"x-internal-token", token}]
    end
  end

  defp req(opts \\ []), do: Req.new([base_url: base_url()] ++ opts)

  # --- カタログ ---
  def catalog do
    case YomimaEx.CatalogCache.get() do
      {:ok, data} ->
        {:ok, data}

      :stale ->
        case fetch_catalog() do
          {:ok, data} ->
            YomimaEx.CatalogCache.put(data)
            {:ok, data}

          err ->
            err
        end
    end
  end

  defp fetch_catalog do
    case req() |> Req.get(url: "/api/public/catalog", headers: internal_headers()) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: s}} -> {:error, "catalog status #{s}"}
      {:error, e} -> {:error, "catalog fetch failed: #{inspect(e)}"}
    end
  end

  def catalog_entry(url) do
    case catalog() do
      {:ok, items} -> Enum.find(items, &(&1["cbz_url"] == url))
      _ -> nil
    end
  end

  # --- 認証 ---
  @doc """
  認証代理送信用ヘッダ（内部トークン＋クライアントキー）。
  クライアントキーは内部トークンと併せて初めてプラットフォームに
  信頼される（Python 版 _auth_proxy_headers と同じ）。
  """
  def auth_headers(conn) do
    case YomimaEx.ClientKey.key_for_conn(conn) do
      "" -> internal_headers()
      key -> internal_headers() ++ [{"x-viewer-client-key", key}]
    end
  end

  def login(username, password, headers) do
    case req()
         |> Req.post(
           url: "/api/auth/token",
           form: [username: username, password: password],
           headers: headers
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, _} -> {:error, :invalid}
      {:error, _} -> {:error, :upstream}
    end
  end

  def me(token) do
    case req() |> Req.get(url: "/api/auth/me", auth: {:bearer, token}) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      _ -> {:error, :upstream}
    end
  end

  def signup(username, email, password, headers) do
    body = %{
      "username" => username,
      "email" => email,
      "password" => password,
      "account_type" => "reader"
    }

    case req() |> Req.post(url: "/api/auth/signup", json: body, headers: headers) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{body: %{"detail" => detail}}} -> {:error, {:detail, detail}}
      {:ok, _} -> {:error, {:detail, "登録に失敗しました"}}
      {:error, _} -> {:error, :upstream}
    end
  end

  def declare_adult(token) do
    case req() |> Req.post(url: "/api/auth/declare-adult", auth: {:bearer, token}) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      _ -> {:error, :upstream}
    end
  end

  def grants(token, user_id) do
    case YomimaEx.Store.get_grants(user_id) do
      nil ->
        case req() |> Req.get(url: "/api/auth/grants", auth: {:bearer, token}) do
          {:ok, %{status: 200, body: body}} ->
            set = MapSet.new(body, &{&1["author_id"], &1["title_id"]})
            YomimaEx.Store.put_grants(user_id, set)
            set

          _ ->
            MapSet.new()
        end

      cached ->
        cached
    end
  end

  # --- CBZ / サムネイルの取得（ダウンロード本体は Manga 側） ---
  def platform_origin?(url) do
    with %URI{} = u <- URI.parse(url),
         %URI{} = b <- URI.parse(base_url()) do
      u.userinfo in [nil, ""] and
        u.scheme == b.scheme and u.host == b.host and
        (u.port || default_port(u.scheme)) == (b.port || default_port(b.scheme))
    else
      _ -> false
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_), do: nil
end

defmodule YomimaEx.CatalogCache do
  use GenServer

  @ttl 60

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def get, do: GenServer.call(__MODULE__, :get)
  def put(data), do: GenServer.call(__MODULE__, {:put, data})

  @impl true
  def init(:ok), do: {:ok, {0, nil}}

  @impl true
  def handle_call(:get, _from, {ts, data} = state) do
    fresh = data != nil and System.system_time(:second) - ts < @ttl
    {:reply, if(fresh, do: {:ok, data}, else: :stale), state}
  end

  def handle_call({:put, data}, _from, _state) do
    {:reply, :ok, {System.system_time(:second), data}}
  end
end
