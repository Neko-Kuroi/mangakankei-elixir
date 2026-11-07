defmodule PlatformEx.LoginThrottle do
  @moduledoc """
  ログインのユーザー名単位の失敗カウンタ。
  Python 版 main.py の _login_failures と同じ意味論：
  直近60秒の失敗が5回に達したらブロックし、成功でリセットする。
  ウィンドウは固定ではなく、失敗のたびに古いものを捨てる滑走方式
  （Python 版が deque で持っているのと同じ）。

  Hammer の固定ウィンドウではこの滑走方式が表せないため、ここだけ自前で持つ。
  """
  use GenServer

  @limit 5
  @window_ms 60_000
  @cleanup_threshold 4096

  # --- API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "直近ウィンドウ内の失敗が上限に達していれば true"
  def blocked?(username), do: GenServer.call(__MODULE__, {:blocked?, username})

  @doc "失敗を1回記録する"
  def record_failure(username), do: GenServer.cast(__MODULE__, {:failure, username})

  @doc "成功したので数え直す"
  def clear(username), do: GenServer.cast(__MODULE__, {:clear, username})

  # --- GenServer ---

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:blocked?, username}, _from, state) do
    {state, q} = prune(state, username, now())
    {:reply, length(q) >= @limit, state}
  end

  @impl true
  def handle_cast({:failure, username}, state) do
    now = now()
    {state, q} = prune(state, username, now)
    state = Map.put(state, username, q ++ [now])
    {:noreply, cleanup(state, now)}
  end

  def handle_cast({:clear, username}, state) do
    {:noreply, Map.delete(state, username)}
  end

  # --- 内部 ---

  defp now, do: System.monotonic_time(:millisecond)

  defp prune(state, username, now) do
    cutoff = now - @window_ms
    q = state |> Map.get(username, []) |> Enum.filter(&(&1 >= cutoff))
    {Map.put(state, username, q), q}
  end

  # Python 版と同じく、たまりすぎたら古いエントリを掃除する
  defp cleanup(state, now) do
    if map_size(state) > @cleanup_threshold do
      cutoff = now - @window_ms

      state
      |> Enum.reject(fn {_name, q} -> q == [] or List.last(q) < cutoff end)
      |> Map.new()
    else
      state
    end
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end
end
