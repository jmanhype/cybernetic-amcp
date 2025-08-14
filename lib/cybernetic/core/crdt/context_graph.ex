
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
    
    # Monitor node connections for distributed sync
    :net_kernel.monitor_nodes(true, node_type: :all)
    
    # Wire neighbors after a brief delay to allow cluster to form
    Process.send_after(self(), :wire_neighbors, 1000)
    
    {:ok, %{crdt: crdt, neighbors: []}}
  end
  
  @doc """
  Enable distributed sync with cluster nodes
  """
  def enable_sync, do: GenServer.cast(__MODULE__, :enable_sync)
  
  @doc """
  Get current neighbor nodes
  """
  def get_neighbors, do: GenServer.call(__MODULE__, :get_neighbors)

  @doc """
  Store a semantic triple (subject, predicate, object) with metadata.
  """
  @spec put_triple(term(), term(), term(), map()) :: :ok
  def put_triple(subject, predicate, object, meta \\ %{}) do
    GenServer.cast(__MODULE__, {:put_triple, subject, predicate, object, meta})
  end

  @doc """
  Query triples by subject, predicate, or object.
  
  Examples:
    query(subject: "user123") - Find all triples with subject "user123"
    query(predicate: "likes") - Find all "likes" relationships  
    query(subject: "user123", predicate: "likes") - Find what user123 likes
    query(%{}) - Get all triples
  """
  @spec query(keyword() | map()) :: list()
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

  def handle_call({:query, criteria}, _from, %{crdt: crdt} = state) do
    all_triples = DeltaCrdt.read(crdt) |> Map.values()
    
    # Filter triples based on criteria
    filtered_triples = filter_triples(all_triples, normalize_criteria(criteria))
    
    {:reply, filtered_triples, state}
  end
  
  def handle_call(:get_neighbors, _from, state) do
    {:reply, state.neighbors, state}
  end

  # Private helper functions

  defp normalize_criteria(criteria) when is_list(criteria), do: Enum.into(criteria, %{})
  defp normalize_criteria(criteria) when is_map(criteria), do: criteria
  defp normalize_criteria(_), do: %{}

  defp filter_triples(triples, criteria) when map_size(criteria) == 0, do: triples
  defp filter_triples(triples, criteria) do
    Enum.filter(triples, &matches_criteria?(&1, criteria))
  end

  defp matches_criteria?(triple, criteria) do
    Enum.all?(criteria, fn
      {:subject, value} -> triple.subject == value
      {"subject", value} -> triple.subject == value
      {:predicate, value} -> triple.predicate == value  
      {"predicate", value} -> triple.predicate == value
      {:object, value} -> triple.object == value
      {"object", value} -> triple.object == value
      {key, value} when key in [:meta, "meta"] -> 
        matches_meta_criteria?(triple.meta, value)
      _ -> true  # Unknown criteria are ignored
    end)
  end

  defp matches_meta_criteria?(meta, criteria) when is_map(criteria) do
    Enum.all?(criteria, fn {key, value} ->
      Map.get(meta, key) == value or Map.get(meta, to_string(key)) == value
    end)
  end
  defp matches_meta_criteria?(meta, value) do
    # Simple equality check for non-map criteria
    meta == value
  end
end
