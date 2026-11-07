defmodule YomimaEx.Store do
  @moduledoc """
  サーバー側の状態（読者ログイン・読書セッション・年齢ゲート・許可キャッシュ）を
  保持する GenServer。Python 版の辞書ストア群に相当する。
  期限切れは30秒ごとの sweep で落とす。
  """
  use GenServer

  @auth_ttl 3600
  @session_ttl 3600
  @age_gate_ttl 30 * 24 * 3600
  @grants_ttl 60

  # --- API ---
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def new_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  # 読者ログイン
  def put_auth(cookie_token, entry),
    do: GenServer.call(__MODULE__, {:put_auth, cookie_token, entry})

  def get_auth(cookie_token), do: GenServer.call(__MODULE__, {:get_auth, cookie_token})
  def delete_auth(cookie_token), do: GenServer.call(__MODULE__, {:delete_auth, cookie_token})

  # 読書セッション
  def put_session(token, entry),
    do: GenServer.call(__MODULE__, {:put_session, token, entry})

  def get_session(token), do: GenServer.call(__MODULE__, {:get_session, token})

  # 年齢ゲート（匿名の自己申告）
  def put_age_gate(cookie_token),
    do: GenServer.call(__MODULE__, {:put_age_gate, cookie_token})

  def age_gate_ok?(cookie_token),
    do: GenServer.call(__MODULE__, {:age_gate_ok, cookie_token})

  # 許可キャッシュ
  def put_grants(user_id, grants),
    do: GenServer.call(__MODULE__, {:put_grants, user_id, grants})

  def get_grants(user_id), do: GenServer.call(__MODULE__, {:get_grants, user_id})

  def auth_ttl, do: @auth_ttl
  def session_ttl, do: @session_ttl
  def age_gate_ttl, do: @age_gate_ttl

  # クライアントキーの秘密（初回に解決してキャッシュ。"" も結果として保持）
  def client_key_secret, do: GenServer.call(__MODULE__, :client_key_secret)

  # テスト用: 秘密のキャッシュを未解決に戻す
  def reset_client_key_secret,
    do: GenServer.call(__MODULE__, :reset_client_key_secret)

  # アーカイブ展開結果のキャッシュ（Python 版 _extract_cache と同じプロセス内メモ）
  def extract_cache(archive), do: GenServer.call(__MODULE__, {:extract_cache, archive})

  def put_extract_cache(archive, value),
    do: GenServer.call(__MODULE__, {:put_extract_cache, archive, value})

  # --- GenServer ---
  @impl true
  def init(:ok) do
    schedule_sweep()
    {:ok,
     %{
       auth: %{},
       sessions: %{},
       age_gates: %{},
       grants: %{},
       client_key_secret: :unresolved,
       extract_cache: %{}
     }}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, 30_000)

  defp now, do: System.system_time(:second)

  @impl true
  def handle_call({:put_auth, token, entry}, _from, state) do
    entry = Map.put(entry, :expires_at, now() + @auth_ttl)
    {:reply, :ok, put_in(state, [:auth, token], entry)}
  end

  def handle_call({:get_auth, token}, _from, state) do
    {:reply, live_entry(state.auth, token), state}
  end

  def handle_call({:delete_auth, token}, _from, state) do
    {:reply, :ok, %{state | auth: Map.delete(state.auth, token)}}
  end

  def handle_call({:put_session, token, entry}, _from, state) do
    entry = Map.put(entry, :expires_at, now() + @session_ttl)
    {:reply, :ok, put_in(state, [:sessions, token], entry)}
  end

  def handle_call({:get_session, token}, _from, state) do
    {:reply, live_entry(state.sessions, token), state}
  end

  def handle_call({:put_age_gate, token}, _from, state) do
    {:reply, :ok, put_in(state, [:age_gates, token], now() + @age_gate_ttl)}
  end

  def handle_call({:age_gate_ok, token}, _from, state) do
    ok =
      case state.age_gates[token] do
        nil -> false
        exp -> exp > now()
      end

    {:reply, ok, state}
  end

  def handle_call({:put_grants, user_id, grants}, _from, state) do
    {:reply, :ok, put_in(state, [:grants, user_id], {now(), grants})}
  end

  def handle_call({:get_grants, user_id}, _from, state) do
    reply =
      case state.grants[user_id] do
        {ts, grants} -> if ts + @grants_ttl > now(), do: grants, else: nil
        _ -> nil
      end

    {:reply, reply, state}
  end

  def handle_call(:client_key_secret, _from, %{client_key_secret: :unresolved} = state) do
    value = YomimaEx.ClientKey.resolve_secret()
    {:reply, value, %{state | client_key_secret: value}}
  end

  def handle_call(:client_key_secret, _from, state) do
    {:reply, state.client_key_secret, state}
  end

  def handle_call(:reset_client_key_secret, _from, state) do
    {:reply, :ok, %{state | client_key_secret: :unresolved}}
  end

  def handle_call({:extract_cache, archive}, _from, state) do
    {:reply, Map.get(state.extract_cache, archive), state}
  end

  def handle_call({:put_extract_cache, archive, value}, _from, state) do
    {:reply, :ok, %{state | extract_cache: Map.put(state.extract_cache, archive, value)}}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep()
    t = now()

    state = %{
      state
      | auth: drop_expired(state.auth, t),
        sessions: drop_expired(state.sessions, t),
        age_gates: drop_expired_values(state.age_gates, t)
    }

    {:noreply, state}
  end

  defp live_entry(map, token) do
    case map[token] do
      nil -> nil
      %{expires_at: exp} = entry -> if exp > now(), do: entry, else: nil
    end
  end

  defp drop_expired(map, t),
    do: Map.filter(map, fn {_k, v} -> v.expires_at > t end)

  defp drop_expired_values(map, t),
    do: Map.filter(map, fn {_k, exp} -> exp > t end)
end
