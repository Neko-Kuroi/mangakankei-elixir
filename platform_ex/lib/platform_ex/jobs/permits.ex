defmodule PlatformEx.Jobs.Permits do
  @moduledoc """
  同時に加工できるジョブ数の上限（Python 版の _upload_semaphore = 2 と同じ）。
  空きがなければ、空くまで呼び出し側を待たせる。
  """
  use GenServer

  @max 2

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "許可を取る（空くまで待つ）"
  def acquire, do: GenServer.call(__MODULE__, :acquire, :infinity)

  @doc "許可を返す"
  def release, do: GenServer.cast(__MODULE__, :release)

  # --- GenServer ---

  @impl true
  def init(:ok), do: {:ok, {@max, :queue.new()}}

  @impl true
  def handle_call(:acquire, from, {available, waiters}) do
    if available > 0 do
      {:reply, :ok, {available - 1, waiters}}
    else
      {:noreply, {available, :queue.in(from, waiters)}}
    end
  end

  @impl true
  def handle_cast(:release, {available, waiters}) do
    case :queue.out(waiters) do
      {{:value, from}, rest} ->
        GenServer.reply(from, :ok)
        {:noreply, {available, rest}}

      {:empty, _} ->
        {:noreply, {min(available + 1, @max), waiters}}
    end
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end
end
