
defmodule Cybernetic.Core.CRDT.ContextGraph do
  @moduledoc """
  Delta CRDT-backed semantic context graph for entity/predicate/object triples with causal metadata.
  Provides distributed state synchronization across VSM systems.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    {:ok, crdt} = DeltaCrdt.start_link(
      DeltaCrdt.AWLWWMap, 
      sync_interval: 50, 
      ship_interval: 50, 
      ship_debounce: 10
    )
    {:ok, %{crdt: crdt}}
  end

  @doc """
  Store a semantic triple (subject, predicate, object) with metadata.
  """
  @spec put_triple(term(), term(), term(), map()) :: :ok
  def put_triple(subject, predicate, object, meta \\ %{}) do
    GenServer.cast(__MODULE__, {:put_triple, subject, predicate, object, meta})
  end

  @doc """
  Query triples by subject, predicate, or object.
  """
  @spec query(subject: term() | nil, predicate: term() | nil, object: term() | nil) :: list()
  def query(criteria) do
    GenServer.call(__MODULE__, {:query, criteria})
  end

  def handle_cast({:put_triple, subject, predicate, object, meta}, %{crdt: crdt} = state) do
    key = :erlang.term_to_binary({subject, predicate, object})
    value = %{
      subject: subject, 
      predicate: predicate, 
      object: object, 
      meta: Map.merge(%{timestamp: System.system_time(:millisecond)}, meta)
    }
    DeltaCrdt.mutate(crdt, :add, [key, value])
    {:noreply, state}
  end

  def handle_call({:query, _criteria}, _from, %{crdt: crdt} = state) do
    # Simple implementation - get all values for now
    # Could be optimized with indexing
    values = DeltaCrdt.read(crdt) |> Map.values()
    {:reply, values, state}
  end
end
