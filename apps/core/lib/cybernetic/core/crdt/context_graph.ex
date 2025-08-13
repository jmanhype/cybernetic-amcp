defmodule Cybernetic.Core.CRDT.ContextGraph do
  @moduledoc """
  Delta CRDT-backed semantic context graph (entity/predicate/object with causal metadata).
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_) do
    {:ok, crdt} = DeltaCrdt.start_link(DeltaCrdt.AWLWWMap, sync_interval: 50, ship_interval: 50, ship_debounce: 10)
    {:ok, %{crdt: crdt}}
  end

  @spec put_triple(term(), term(), term(), map()) :: :ok
  def put_triple(s, p, o, meta \\ %{}) do
    key = :erlang.term_to_binary({s, p, o})
    value = %{s: s, p: p, o: o, meta: Map.merge(%{ts: System.system_time(:millisecond)}, meta)}
    GenServer.cast(__MODULE__, {:put, key, value})
  end

  def handle_cast({:put, key, value}, %{crdt: crdt} = st) do
    DeltaCrdt.mutate(crdt, :add, [key, value])
    {:noreply, st}
  end
end
