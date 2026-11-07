defmodule PlatformEx.ViewCounts do
  @moduledoc """
  閲覧数カウントのクールダウン（メモリ内）。
  Python 版 _view_cooldown と同じ：同じ作品×同じ IP は1時間に1回までで、
  記録は書き込みが成功したときにだけ更新される。
  """
  use GenServer

  @cooldown_seconds 3600

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "クールダウンが明けているか（記録は変えない）"
  def ready?(key) do
    GenServer.call(__MODULE__, {:ready, key, System.os_time(:second)})
  end

  @doc "カウントしたことを記録する"
  def mark(key) do
    GenServer.call(__MODULE__, {:mark, key, System.os_time(:second)})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:ready, key, now}, _from, state) do
    last = Map.get(state, key, 0)
    {:reply, now - last >= @cooldown_seconds, state}
  end

  def handle_call({:mark, key, now}, _from, state) do
    {:reply, :ok, Map.put(state, key, now)}
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end
end
