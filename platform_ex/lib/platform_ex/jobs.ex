defmodule PlatformEx.Jobs do
  @moduledoc """
  アップロードジョブの進捗ストア（メモリ内）。
  Python 版の upload_progress と同じ：再起動で消え、
  done/error の進捗は読み取り時に取り除かれる（コントローラ側で行う）。

  進捗は %{"phase" => _, "current" => _, "total" => _, ...} の形で持つ。
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "job_id を発行する（uuid4 の hex 32文字、Python 版と同じ形）"
  def new_job_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @doc "進捗を丸ごと差し替える（Python 版 update_progress と同じ）。画面（LiveView）へも PubSub で流す"
  def update(job_id, phase, current, total, extra \\ %{}) do
    progress =
      Map.merge(
        %{"phase" => phase, "current" => current, "total" => total},
        extra
      )

    GenServer.call(__MODULE__, {:put, job_id, progress})

    Phoenix.PubSub.broadcast(
      PlatformEx.PubSub,
      "job:#{job_id}",
      {:job_progress, job_id, progress}
    )

    :ok
  end

  @doc "進捗を引く"
  def get(job_id), do: GenServer.call(__MODULE__, {:get, job_id})

  @doc "進捗を取り除く"
  def pop(job_id), do: GenServer.call(__MODULE__, {:pop, job_id})

  # --- GenServer ---

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:put, job_id, progress}, _from, state) do
    {:reply, :ok, Map.put(state, job_id, progress)}
  end

  def handle_call({:pop, job_id}, _from, state) do
    {:reply, :ok, Map.delete(state, job_id)}
  end

  def handle_call({:get, job_id}, _from, state) do
    {:reply, Map.fetch(state, job_id), state}
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end
end
