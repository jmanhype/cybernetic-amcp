
defmodule Cybernetic.Security.NonceBloom do
  @moduledoc """
  Nonce replay prevention using a simple ETS-based Bloom-ish filter with TTL.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def seen?(nonce), do: GenServer.call(__MODULE__, {:seen?, nonce})
  def remember(nonce), do: GenServer.cast(__MODULE__, {:remember, nonce})

  def init(_opts) do
    tid = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    ttl = Application.get_env(:cybernetic, __MODULE__, [])[:ttl_ms] || 60_000
    Process.send_after(self(), :gc, ttl)
    {:ok, %{tid: tid, ttl: ttl}}
  end

  def handle_call({:seen?, nonce}, _from, %{tid: tid} = state) do
    {:reply, :ets.member(tid, nonce), state}
  end

  def handle_cast({:remember, nonce}, %{tid: tid} = state) do
    :ets.insert(tid, {nonce, System.monotonic_time()})
    {:noreply, state}
  end

  def handle_info(:gc, %{tid: tid, ttl: ttl} = state) do
    now = System.monotonic_time()
    for {nonce, ts} <- :ets.tab2list(tid) do
      if System.convert_time_unit(now - ts, :native, :millisecond) > ttl do
        :ets.delete(tid, nonce)
      end
    end
    Process.send_after(self(), :gc, ttl)
    {:noreply, state}
  end
end
