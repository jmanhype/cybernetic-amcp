defmodule Cybernetic.Security.Nonce do
  @moduledoc """
  Nonce tracking with a probabilistic Bloom filter for replay prevention.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(_) do
    cfg = Application.get_env(:cybernetic, __MODULE__, [])
    {:ok, %{seen: MapSet.new(), ttl: cfg[:ttl_ms] || 86_400_000}}
  end

  def seen?(nonce), do: GenServer.call(__MODULE__, {:seen?, nonce})
  def mark!(nonce), do: GenServer.cast(__MODULE__, {:mark, nonce})

  def handle_call({:seen?, n}, _from, %{seen: s} = st), do: {:reply, MapSet.member?(s, n), st}
  def handle_cast({:mark, n}, %{seen: s} = st), do: {:noreply, %{st | seen: MapSet.put(s, n)}}
end
