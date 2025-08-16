defmodule Cybernetic.Core.CRDT.Graph do
  @moduledoc """
  CRDT-based distributed graph implementation.
  Provides eventually consistent graph operations across nodes.
  """
  use GenServer
  require Logger

  @table :crdt_graph

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Create ETS table for graph storage
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    
    {:ok, %{
      nodes: %{},
      edges: %{},
      version: 0
    }}
  end

  # Node operations

  @doc "Add a node to the graph"
  def add_node(node_id, metadata \\ %{}) do
    timestamp = System.system_time(:millisecond)
    node = %{
      id: node_id,
      metadata: metadata,
      timestamp: timestamp,
      version: 1
    }
    :ets.insert(@table, {{:node, node_id}, node})
    {:ok, node}
  end

  @doc "Get a node by ID"
  def get_node(node_id) do
    case :ets.lookup(@table, {:node, node_id}) do
      [{_, node}] -> {:ok, node}
      [] -> {:error, :not_found}
    end
  end

  @doc "Get all nodes"
  def get_all_nodes do
    :ets.match(@table, {{:node, :"$1"}, :"$2"})
    |> Enum.map(fn [_id, node] -> node end)
  end

  # Edge operations

  @doc "Add an edge between two nodes"
  def add_edge(from_id, to_id, metadata \\ %{}) do
    timestamp = System.system_time(:millisecond)
    edge_id = {from_id, to_id}
    edge = %{
      from: from_id,
      to: to_id,
      metadata: metadata,
      timestamp: timestamp,
      version: 1
    }
    :ets.insert(@table, {{:edge, edge_id}, edge})
    
    # Update adjacency lists
    update_adjacency(from_id, to_id, :outgoing)
    update_adjacency(to_id, from_id, :incoming)
    
    {:ok, edge}
  end

  @doc "Get an edge between two nodes"
  def get_edge(from_id, to_id) do
    case :ets.lookup(@table, {:edge, {from_id, to_id}}) do
      [{_, edge}] -> {:ok, edge}
      [] -> {:error, :not_found}
    end
  end

  @doc "Get all edges from a node"
  def get_outgoing_edges(node_id) do
    pattern = {{:edge, {node_id, :"$1"}}, :"$2"}
    :ets.match(@table, pattern)
    |> Enum.map(fn [_to_id, edge] -> edge end)
  end

  @doc "Get all edges to a node"
  def get_incoming_edges(node_id) do
    pattern = {{:edge, {:"$1", node_id}}, :"$2"}
    :ets.match(@table, pattern)
    |> Enum.map(fn [_from_id, edge] -> edge end)
  end

  # Neighbor operations

  @doc "Get outgoing neighbors of a node"
  def get_outgoing_neighbors(node_id) do
    case :ets.lookup(@table, {:adjacency, node_id, :outgoing}) do
      [{_, neighbors}] -> MapSet.to_list(neighbors)
      [] -> []
    end
  end

  @doc "Get incoming neighbors of a node"
  def get_incoming_neighbors(node_id) do
    case :ets.lookup(@table, {:adjacency, node_id, :incoming}) do
      [{_, neighbors}] -> MapSet.to_list(neighbors)
      [] -> []
    end
  end

  @doc "Get all neighbors (both incoming and outgoing)"
  def get_all_neighbors(node_id) do
    outgoing = get_outgoing_neighbors(node_id)
    incoming = get_incoming_neighbors(node_id)
    Enum.uniq(outgoing ++ incoming)
  end

  # CRDT Merge operations

  @doc "Merge another graph state into this one"
  def merge(remote_state) do
    GenServer.call(__MODULE__, {:merge, remote_state})
  end

  @doc "Get current graph state for replication"
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  # Server callbacks

  def handle_call({:merge, remote_state}, _from, state) do
    # Simple LWW (Last Write Wins) merge based on timestamps
    merged_state = merge_states(state, remote_state)
    {:reply, {:ok, merged_state}, merged_state}
  end

  def handle_call(:get_state, _from, state) do
    # Export current ETS state
    nodes = :ets.match_object(@table, {{:node, :_}, :_})
    edges = :ets.match_object(@table, {{:edge, :_}, :_})
    
    export = %{
      nodes: nodes,
      edges: edges,
      version: state.version
    }
    
    {:reply, export, state}
  end

  # Private helpers

  defp update_adjacency(from_id, to_id, direction) do
    key = {:adjacency, from_id, direction}
    
    neighbors = case :ets.lookup(@table, key) do
      [{_, existing}] -> existing
      [] -> MapSet.new()
    end
    
    updated = MapSet.put(neighbors, to_id)
    :ets.insert(@table, {key, updated})
  end

  defp merge_states(local, remote) do
    # Merge nodes - keep the one with higher version/timestamp
    Enum.each(remote.nodes, fn {{:node, id}, node} ->
      case :ets.lookup(@table, {:node, id}) do
        [{_, local_node}] ->
          if node.timestamp > local_node.timestamp do
            :ets.insert(@table, {{:node, id}, node})
          end
        [] ->
          :ets.insert(@table, {{:node, id}, node})
      end
    end)
    
    # Merge edges similarly
    Enum.each(remote.edges, fn {{:edge, edge_id}, edge} ->
      case :ets.lookup(@table, {:edge, edge_id}) do
        [{_, local_edge}] ->
          if edge.timestamp > local_edge.timestamp do
            :ets.insert(@table, {{:edge, edge_id}, edge})
          end
        [] ->
          :ets.insert(@table, {{:edge, edge_id}, edge})
      end
    end)
    
    %{local | version: max(local.version, remote.version) + 1}
  end
end