defmodule PlatformEx.SettingsLock do
  @moduledoc """
  settings.json の読み→更新→書きを直列化する錠前
  （Python 版の _settings_lock と同じ役割）。
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "fun を錠前の中で実行し、結果を返す"
  def with_lock(fun), do: GenServer.call(__MODULE__, {:run, fun}, :infinity)

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_call({:run, fun}, _from, state) do
    {:reply, fun.(), state}
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end
end
