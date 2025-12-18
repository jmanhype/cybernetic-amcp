defmodule Cybernetic.Intelligence.HNSW.Index do
  @moduledoc """
  Hierarchical Navigable Small World (HNSW) index for fast vector similarity search.

  Implements approximate nearest neighbor search with:
  - Multi-layer graph structure
  - Configurable M (max connections per node)
  - ef_construction for build quality
  - ef_search for query quality/speed tradeoff

  ## Usage

      # Create index
      {:ok, _} = Index.start_link(dimensions: 384, m: 16)

      # Insert vectors
      :ok = Index.insert("doc_1", [0.1, 0.2, ...])

      # Search
      {:ok, results} = Index.search([0.15, 0.25, ...], k: 10)
      # => [{id: "doc_1", distance: 0.05, vector: [...]}]
  """
  use GenServer

  require Logger

  @type vector :: [float()]
  @type node_id :: String.t()
  @type distance :: float()

  @type hnsw_node :: %{
          id: node_id(),
          vector: vector(),
          layer: non_neg_integer(),
          neighbors: %{non_neg_integer() => [node_id()]}
        }

  @type search_result :: %{
          id: node_id(),
          distance: distance(),
          vector: vector()
        }

  # Default HNSW parameters
  @default_m 16            # Max connections per node per layer
  @default_ef_construction 200  # Build-time beam width
  @default_ef_search 50    # Search-time beam width
  @default_ml 1.0 / :math.log(16)  # Level multiplier

  @telemetry [:cybernetic, :intelligence, :hnsw]

  # Client API

  @doc "Start the HNSW index"
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Insert a vector with ID"
  @spec insert(node_id(), vector(), keyword()) :: :ok | {:error, term()}
  def insert(id, vector, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:insert, id, vector}, :infinity)
  end

  @doc "Batch insert multiple vectors"
  @spec insert_batch([{node_id(), vector()}], keyword()) :: :ok
  def insert_batch(items, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:insert_batch, items}, :infinity)
  end

  @doc "Search for k nearest neighbors"
  @spec search(vector(), keyword()) :: {:ok, [search_result()]} | {:error, term()}
  def search(query_vector, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    k = Keyword.get(opts, :k, 10)
    ef = Keyword.get(opts, :ef, @default_ef_search)
    GenServer.call(server, {:search, query_vector, k, ef})
  end

  @doc "Delete a vector by ID"
  @spec delete(node_id(), keyword()) :: :ok | {:error, :not_found}
  def delete(id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:delete, id})
  end

  @doc "Get index statistics"
  @spec stats(keyword()) :: map()
  def stats(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :stats)
  end

  @doc "Check if ID exists"
  @spec exists?(node_id(), keyword()) :: boolean()
  def exists?(id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:exists, id})
  end

  @doc "Get vector by ID"
  @spec get(node_id(), keyword()) :: {:ok, vector()} | {:error, :not_found}
  def get(id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get, id})
  end

  @doc "Clear all vectors"
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :clear)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("HNSW Index starting")

    state = %{
      nodes: %{},                # id => node
      entry_point: nil,          # ID of entry point node
      max_layer: 0,              # Current maximum layer
      dimensions: Keyword.get(opts, :dimensions, 384),
      m: Keyword.get(opts, :m, @default_m),
      m_max: Keyword.get(opts, :m_max, @default_m),
      m_max_0: Keyword.get(opts, :m_max_0, @default_m * 2),  # Double M for layer 0
      ef_construction: Keyword.get(opts, :ef_construction, @default_ef_construction),
      ml: Keyword.get(opts, :ml, @default_ml),
      stats: %{
        inserts: 0,
        searches: 0,
        deletes: 0,
        total_distance_computations: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:insert, id, vector}, _from, state) do
    start_time = System.monotonic_time(:microsecond)

    case validate_vector(vector, state.dimensions) do
      :ok ->
        {new_state, distance_comps} = insert_node(state, id, vector)

        new_stats =
          new_state.stats
          |> Map.update!(:inserts, &(&1 + 1))
          |> Map.update!(:total_distance_computations, &(&1 + distance_comps))

        duration = System.monotonic_time(:microsecond) - start_time
        emit_telemetry(:insert, %{duration_us: duration, id: id})

        {:reply, :ok, %{new_state | stats: new_stats}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:insert_batch, items}, _from, state) do
    start_time = System.monotonic_time(:microsecond)

    new_state =
      Enum.reduce(items, state, fn {id, vector}, acc ->
        case validate_vector(vector, acc.dimensions) do
          :ok ->
            {updated, _} = insert_node(acc, id, vector)
            update_in(updated, [:stats, :inserts], &(&1 + 1))

          {:error, _} ->
            acc
        end
      end)

    duration = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:insert_batch, %{duration_us: duration, count: length(items)})

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:search, query_vector, k, ef}, _from, state) do
    start_time = System.monotonic_time(:microsecond)

    case validate_vector(query_vector, state.dimensions) do
      :ok when state.entry_point == nil ->
        {:reply, {:ok, []}, state}

      :ok ->
        {results, distance_comps} = search_knn(state, query_vector, k, ef)

        new_stats =
          state.stats
          |> Map.update!(:searches, &(&1 + 1))
          |> Map.update!(:total_distance_computations, &(&1 + distance_comps))

        duration = System.monotonic_time(:microsecond) - start_time
        emit_telemetry(:search, %{duration_us: duration, k: k, results: length(results)})

        {:reply, {:ok, results}, %{state | stats: new_stats}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    case Map.get(state.nodes, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      node ->
        # Remove from all neighbor lists
        new_nodes =
          Enum.reduce(state.nodes, %{}, fn {nid, n}, acc ->
            if nid == id do
              acc
            else
              updated_neighbors =
                Enum.into(n.neighbors, %{}, fn {layer, neighbors} ->
                  {layer, List.delete(neighbors, id)}
                end)

              Map.put(acc, nid, %{n | neighbors: updated_neighbors})
            end
          end)

        # Update entry point if needed
        new_entry =
          if state.entry_point == id do
            case Map.keys(new_nodes) do
              [] -> nil
              [first | _] -> first
            end
          else
            state.entry_point
          end

        new_stats = Map.update!(state.stats, :deletes, &(&1 + 1))

        {:reply, :ok,
         %{state | nodes: new_nodes, entry_point: new_entry, stats: new_stats}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      state.stats
      |> Map.put(:node_count, map_size(state.nodes))
      |> Map.put(:max_layer, state.max_layer)
      |> Map.put(:dimensions, state.dimensions)
      |> Map.put(:m, state.m)
      |> Map.put(:ef_construction, state.ef_construction)

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:exists, id}, _from, state) do
    {:reply, Map.has_key?(state.nodes, id), state}
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    case Map.get(state.nodes, id) do
      nil -> {:reply, {:error, :not_found}, state}
      node -> {:reply, {:ok, node.vector}, state}
    end
  end

  @impl true
  def handle_call(:clear, _from, state) do
    new_state = %{
      state
      | nodes: %{},
        entry_point: nil,
        max_layer: 0
    }

    {:reply, :ok, new_state}
  end

  # Private Functions - HNSW Algorithm

  @spec insert_node(map(), node_id(), vector()) :: {map(), non_neg_integer()}
  defp insert_node(state, id, vector) do
    # Assign random layer
    node_layer = random_layer(state.ml)

    # Create new node
    node = %{
      id: id,
      vector: vector,
      layer: node_layer,
      neighbors: %{}
    }

    # First node case
    if state.entry_point == nil do
      new_nodes = Map.put(state.nodes, id, node)

      {%{state | nodes: new_nodes, entry_point: id, max_layer: node_layer}, 0}
    else
      # Insert into graph
      {new_nodes, distance_comps} =
        insert_into_graph(state, id, node, state.entry_point, state.max_layer)

      # Update entry point if new node has higher layer
      {new_entry, new_max} =
        if node_layer > state.max_layer do
          {id, node_layer}
        else
          {state.entry_point, state.max_layer}
        end

      {%{state | nodes: new_nodes, entry_point: new_entry, max_layer: new_max}, distance_comps}
    end
  end

  @spec insert_into_graph(map(), node_id(), node(), node_id(), non_neg_integer()) ::
          {map(), non_neg_integer()}
  defp insert_into_graph(state, new_id, new_node, entry_point, max_layer) do
    # Start from entry point
    current = entry_point
    distance_comps = 0

    # Traverse from top layer to new_node.layer + 1
    {current, distance_comps} =
      Enum.reduce((max_layer)..(new_node.layer + 1)//-1, {current, distance_comps}, fn layer, {curr, comps} ->
        entry_node = Map.get(state.nodes, curr)
        {nearest, new_comps} = search_layer_greedy(state, new_node.vector, entry_node, layer)
        {nearest.id, comps + new_comps}
      end)

    # Insert into layers new_node.layer down to 0
    nodes_with_new = Map.put(state.nodes, new_id, new_node)

    {final_nodes, total_comps} =
      Enum.reduce(min(new_node.layer, max_layer)..0//-1, {nodes_with_new, distance_comps}, fn layer, {nodes, comps} ->
        entry_node = Map.get(nodes, current)
        m_max = if layer == 0, do: state.m_max_0, else: state.m_max

        # Search for ef_construction nearest neighbors at this layer
        {candidates, search_comps} =
          search_layer(nodes, new_node.vector, entry_node, layer, state.ef_construction)

        # Select M best neighbors
        neighbors = select_neighbors(candidates, state.m)

        # Connect new node to neighbors
        updated_new = Map.get(nodes, new_id)
        updated_new = %{updated_new | neighbors: Map.put(updated_new.neighbors, layer, neighbors)}
        nodes = Map.put(nodes, new_id, updated_new)

        # Add reverse connections
        nodes =
          Enum.reduce(neighbors, nodes, fn neighbor_id, acc ->
            neighbor = Map.get(acc, neighbor_id)

            if neighbor do
              current_neighbors = Map.get(neighbor.neighbors, layer, [])
              new_neighbors = [new_id | current_neighbors]

              # Prune if exceeds m_max
              pruned =
                if length(new_neighbors) > m_max do
                  prune_neighbors(acc, neighbor.vector, new_neighbors, m_max)
                else
                  new_neighbors
                end

              updated = %{neighbor | neighbors: Map.put(neighbor.neighbors, layer, pruned)}
              Map.put(acc, neighbor_id, updated)
            else
              acc
            end
          end)

        # Update current for next layer
        # Note: new_current would be used for multi-layer traversal optimization
        # but we already traverse through neighbors in the search
        _new_current =
          case neighbors do
            [first | _] -> first
            [] -> current
          end

        {nodes, comps + search_comps}
      end)

    {final_nodes, total_comps}
  end

  @spec search_knn(map(), vector(), pos_integer(), pos_integer()) ::
          {[search_result()], non_neg_integer()}
  defp search_knn(state, query, k, ef) do
    entry_node = Map.get(state.nodes, state.entry_point)
    distance_comps = 0

    # Traverse from top layer to layer 1
    {current, distance_comps} =
      Enum.reduce(state.max_layer..1//-1, {entry_node, distance_comps}, fn layer, {curr, comps} ->
        {nearest, new_comps} = search_layer_greedy(state, query, curr, layer)
        {nearest, comps + new_comps}
      end)

    # Search layer 0 with ef
    {candidates, search_comps} = search_layer(state.nodes, query, current, 0, max(ef, k))

    # Return top k results
    results =
      candidates
      |> Enum.take(k)
      |> Enum.map(fn {id, dist} ->
        node = Map.get(state.nodes, id)

        %{
          id: id,
          distance: dist,
          vector: node.vector
        }
      end)

    {results, distance_comps + search_comps}
  end

  @spec search_layer_greedy(map(), vector(), node(), non_neg_integer()) ::
          {node(), non_neg_integer()}
  defp search_layer_greedy(state, query, entry, layer) do
    current = entry
    current_dist = euclidean_distance(query, entry.vector)
    distance_comps = 1
    changed = true

    search_greedy_loop(state, query, current, current_dist, layer, distance_comps, changed)
  end

  defp search_greedy_loop(_state, _query, current, _current_dist, _layer, comps, false) do
    {current, comps}
  end

  defp search_greedy_loop(state, query, current, current_dist, layer, comps, true) do
    neighbors = Map.get(current.neighbors, layer, [])

    {best, best_dist, new_comps} =
      Enum.reduce(neighbors, {current, current_dist, 0}, fn neighbor_id, {best, best_dist, c} ->
        neighbor = Map.get(state.nodes, neighbor_id)

        if neighbor do
          dist = euclidean_distance(query, neighbor.vector)

          if dist < best_dist do
            {neighbor, dist, c + 1}
          else
            {best, best_dist, c + 1}
          end
        else
          {best, best_dist, c}
        end
      end)

    if best.id != current.id do
      search_greedy_loop(state, query, best, best_dist, layer, comps + new_comps, true)
    else
      {current, comps + new_comps}
    end
  end

  @spec search_layer(map(), vector(), node(), non_neg_integer(), pos_integer()) ::
          {[{node_id(), distance()}], non_neg_integer()}
  defp search_layer(nodes, query, entry, layer, ef) do
    entry_dist = euclidean_distance(query, entry.vector)
    distance_comps = 1

    # Priority queue: {distance, id}, sorted by distance ascending
    candidates = [{entry_dist, entry.id}]
    visited = MapSet.new([entry.id])

    # Result list: {distance, id}
    results = [{entry_dist, entry.id}]

    {final_results, total_comps} =
      search_layer_loop(nodes, query, layer, ef, candidates, visited, results, distance_comps)

    {Enum.sort_by(final_results, fn {dist, _} -> dist end), total_comps}
  end

  defp search_layer_loop(_nodes, _query, _layer, _ef, [], _visited, results, comps) do
    {results, comps}
  end

  defp search_layer_loop(nodes, query, layer, ef, [{c_dist, c_id} | rest], visited, results, comps) do
    # Get furthest result distance
    furthest_dist =
      case results do
        [] -> :infinity
        _ -> results |> Enum.max_by(fn {d, _} -> d end) |> elem(0)
      end

    if c_dist > furthest_dist do
      # Can stop - candidate is further than worst result
      {results, comps}
    else
      # Explore neighbors
      node = Map.get(nodes, c_id)
      neighbors = if node, do: Map.get(node.neighbors, layer, []), else: []

      {new_candidates, new_visited, new_results, new_comps} =
        Enum.reduce(neighbors, {rest, visited, results, 0}, fn n_id, {cands, vis, res, c} ->
          if MapSet.member?(vis, n_id) do
            {cands, vis, res, c}
          else
            neighbor = Map.get(nodes, n_id)

            if neighbor do
              dist = euclidean_distance(query, neighbor.vector)
              new_vis = MapSet.put(vis, n_id)

              # Add to results if better than worst or results not full
              new_res =
                if length(res) < ef or dist < furthest_dist do
                  [{dist, n_id} | res]
                  |> Enum.sort_by(fn {d, _} -> d end)
                  |> Enum.take(ef)
                else
                  res
                end

              # Add to candidates
              new_cands = insert_sorted([{dist, n_id}], cands)

              {new_cands, new_vis, new_res, c + 1}
            else
              {cands, vis, res, c}
            end
          end
        end)

      search_layer_loop(
        nodes,
        query,
        layer,
        ef,
        new_candidates,
        new_visited,
        new_results,
        comps + new_comps
      )
    end
  end

  @spec select_neighbors([{node_id(), distance()}], pos_integer()) :: [node_id()]
  defp select_neighbors(candidates, m) do
    candidates
    |> Enum.sort_by(fn {_id, dist} -> dist end)
    |> Enum.take(m)
    |> Enum.map(fn {id, _dist} -> id end)
  end

  @spec prune_neighbors(map(), vector(), [node_id()], pos_integer()) :: [node_id()]
  defp prune_neighbors(nodes, node_vector, neighbors, m_max) do
    # Sort by distance to node
    neighbors
    |> Enum.map(fn id ->
      neighbor = Map.get(nodes, id)
      dist = if neighbor, do: euclidean_distance(node_vector, neighbor.vector), else: :infinity
      {id, dist}
    end)
    |> Enum.sort_by(fn {_id, dist} -> dist end)
    |> Enum.take(m_max)
    |> Enum.map(fn {id, _} -> id end)
  end

  @spec insert_sorted([{distance(), node_id()}], [{distance(), node_id()}]) ::
          [{distance(), node_id()}]
  defp insert_sorted([], acc), do: acc

  defp insert_sorted([item | rest], acc) do
    insert_sorted(rest, insert_one_sorted(item, acc))
  end

  defp insert_one_sorted(item, []), do: [item]

  defp insert_one_sorted({d1, _} = item, [{d2, _} = head | tail]) when d1 <= d2 do
    [item, head | tail]
  end

  defp insert_one_sorted(item, [head | tail]) do
    [head | insert_one_sorted(item, tail)]
  end

  @spec random_layer(float()) :: non_neg_integer()
  defp random_layer(ml) do
    floor(-:math.log(:rand.uniform()) * ml)
  end

  @spec euclidean_distance(vector(), vector()) :: distance()
  defp euclidean_distance(v1, v2) when length(v1) == length(v2) do
    v1
    |> Enum.zip(v2)
    |> Enum.reduce(0.0, fn {a, b}, acc ->
      diff = a - b
      acc + diff * diff
    end)
    |> :math.sqrt()
  end

  defp euclidean_distance(_, _), do: :infinity

  @spec validate_vector(term(), pos_integer()) :: :ok | {:error, :invalid_dimensions}
  defp validate_vector(vector, dimensions) when is_list(vector) do
    if length(vector) == dimensions and Enum.all?(vector, &is_number/1) do
      :ok
    else
      {:error, :invalid_dimensions}
    end
  end

  defp validate_vector(_, _), do: {:error, :invalid_dimensions}

  @spec emit_telemetry(atom(), map()) :: :ok
  defp emit_telemetry(event, metadata) do
    :telemetry.execute(@telemetry ++ [event], %{count: 1}, metadata)
  end
end
