defmodule Cybernetic.Intelligence.Cache.DeterministicCache do
  @moduledoc """
  Content-addressable cache with Bloom filter for fast existence checks.

  Features:
  - Content-addressable storage (SHA256 hash keys)
  - Bloom filter for O(1) membership testing (~1% false positive rate)
  - TTL-based expiration
  - LRU eviction when capacity exceeded
  - Telemetry instrumentation

  ## Usage

      # Store content
      {:ok, key} = DeterministicCache.put(content)

      # Fast existence check (may have false positives)
      true = DeterministicCache.probably_exists?(key)

      # Definitive get
      {:ok, content} = DeterministicCache.get(key)

      # Get with metadata
      {:ok, entry} = DeterministicCache.get_entry(key)
  """
  use GenServer

  require Logger

  @type cache_key :: String.t()
  @type cache_entry :: %{
          key: cache_key(),
          content: binary(),
          content_type: String.t(),
          size: non_neg_integer(),
          hash: binary(),
          created_at: DateTime.t(),
          accessed_at: DateTime.t(),
          ttl: non_neg_integer(),
          hits: non_neg_integer()
        }

  # Bloom filter parameters for ~1% false positive rate at 100k items
  # m = -n*ln(p) / (ln(2)^2) ≈ 958,506 bits for n=100k, p=0.01
  # k = m/n * ln(2) ≈ 7 hash functions
  @bloom_size 1_000_000
  @bloom_hash_count 7

  @default_ttl :timer.hours(24)
  @default_max_size 10_000
  @default_max_memory 100 * 1024 * 1024  # 100MB

  @telemetry [:cybernetic, :intelligence, :cache]

  # Client API

  @doc "Start the deterministic cache"
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Store content and return its content-addressable key"
  @spec put(binary(), keyword()) :: {:ok, cache_key()} | {:error, term()}
  def put(content, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    GenServer.call(server, {:put, content, content_type, ttl})
  end

  @doc "Get content by key"
  @spec get(cache_key(), keyword()) :: {:ok, binary()} | {:error, :not_found}
  def get(key, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get, key})
  end

  @doc "Get full entry with metadata"
  @spec get_entry(cache_key(), keyword()) :: {:ok, cache_entry()} | {:error, :not_found}
  def get_entry(key, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get_entry, key})
  end

  @doc "Fast existence check using Bloom filter (may have false positives)"
  @spec probably_exists?(cache_key(), keyword()) :: boolean()
  def probably_exists?(key, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:probably_exists, key})
  end

  @doc "Definitive existence check"
  @spec exists?(cache_key(), keyword()) :: boolean()
  def exists?(key, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:exists, key})
  end

  @doc "Delete entry by key"
  @spec delete(cache_key(), keyword()) :: :ok
  def delete(key, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:delete, key})
  end

  @doc "Clear all entries"
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :clear)
  end

  @doc "Get cache statistics"
  @spec stats(keyword()) :: map()
  def stats(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :stats)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Deterministic Cache starting")

    state = %{
      cache: %{},
      bloom: :atomics.new(@bloom_size, signed: false),
      access_order: [],  # LRU tracking: [oldest | ... | newest]
      max_size: Keyword.get(opts, :max_size, @default_max_size),
      max_memory: Keyword.get(opts, :max_memory, @default_max_memory),
      current_memory: 0,
      stats: %{
        hits: 0,
        misses: 0,
        bloom_false_positives: 0,
        evictions: 0,
        puts: 0
      }
    }

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call({:put, content, content_type, ttl}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    # Generate content-addressable key
    hash = :crypto.hash(:sha256, content)
    key = Base.encode16(hash, case: :lower)

    # Check if already exists
    if Map.has_key?(state.cache, key) do
      # Update access time for LRU
      new_state = update_access_time(state, key)
      emit_telemetry(:put, start_time, %{status: :exists, key: key})
      {:reply, {:ok, key}, new_state}
    else
      now = DateTime.utc_now()
      size = byte_size(content)

      entry = %{
        key: key,
        content: content,
        content_type: content_type,
        size: size,
        hash: hash,
        created_at: now,
        accessed_at: now,
        ttl: ttl,
        hits: 0
      }

      # Add to bloom filter
      new_bloom = add_to_bloom(state.bloom, key)

      # Evict if needed
      state_after_eviction = maybe_evict(state, size)

      new_state = %{
        state_after_eviction
        | cache: Map.put(state_after_eviction.cache, key, entry),
          bloom: new_bloom,
          access_order: state_after_eviction.access_order ++ [key],
          current_memory: state_after_eviction.current_memory + size,
          stats: Map.update!(state_after_eviction.stats, :puts, &(&1 + 1))
      }

      emit_telemetry(:put, start_time, %{status: :created, key: key, size: size})
      {:reply, {:ok, key}, new_state}
    end
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    case Map.get(state.cache, key) do
      nil ->
        new_stats = Map.update!(state.stats, :misses, &(&1 + 1))
        emit_telemetry(:get, start_time, %{status: :miss, key: key})
        {:reply, {:error, :not_found}, %{state | stats: new_stats}}

      entry ->
        # Check TTL
        if expired?(entry) do
          new_state = remove_entry(state, key)
          emit_telemetry(:get, start_time, %{status: :expired, key: key})
          {:reply, {:error, :not_found}, new_state}
        else
          new_state =
            state
            |> update_access_time(key)
            |> update_in([:cache, key, :hits], &(&1 + 1))
            |> update_in([:stats, :hits], &(&1 + 1))

          emit_telemetry(:get, start_time, %{status: :hit, key: key})
          {:reply, {:ok, entry.content}, new_state}
        end
    end
  end

  @impl true
  def handle_call({:get_entry, key}, _from, state) do
    case Map.get(state.cache, key) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        if expired?(entry) do
          new_state = remove_entry(state, key)
          {:reply, {:error, :not_found}, new_state}
        else
          new_state = update_access_time(state, key)
          {:reply, {:ok, entry}, new_state}
        end
    end
  end

  @impl true
  def handle_call({:probably_exists, key}, _from, state) do
    result = bloom_contains?(state.bloom, key)

    # Track false positives for stats
    new_state =
      if result and not Map.has_key?(state.cache, key) do
        update_in(state, [:stats, :bloom_false_positives], &(&1 + 1))
      else
        state
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:exists, key}, _from, state) do
    case Map.get(state.cache, key) do
      nil ->
        {:reply, false, state}

      entry ->
        if expired?(entry) do
          new_state = remove_entry(state, key)
          {:reply, false, new_state}
        else
          {:reply, true, state}
        end
    end
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    new_state = remove_entry(state, key)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    new_state = %{
      state
      | cache: %{},
        bloom: :atomics.new(@bloom_size, signed: false),
        access_order: [],
        current_memory: 0
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      state.stats
      |> Map.put(:entries, map_size(state.cache))
      |> Map.put(:memory_bytes, state.current_memory)
      |> Map.put(:hit_rate, calculate_hit_rate(state.stats))
      |> Map.put(:bloom_fp_rate, calculate_bloom_fp_rate(state.stats))

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = DateTime.utc_now()

    # Find and remove expired entries
    {expired_keys, _} =
      Enum.reduce(state.cache, {[], 0}, fn {key, entry}, {keys, count} ->
        if expired?(entry, now) do
          {[key | keys], count + 1}
        else
          {keys, count}
        end
      end)

    new_state =
      Enum.reduce(expired_keys, state, fn key, acc ->
        remove_entry(acc, key)
      end)

    if length(expired_keys) > 0 do
      Logger.debug("Cache cleanup removed #{length(expired_keys)} expired entries")
    end

    schedule_cleanup()

    {:noreply, new_state}
  end

  # Private Functions

  @spec add_to_bloom(:atomics.atomics_ref(), cache_key()) :: :atomics.atomics_ref()
  defp add_to_bloom(bloom, key) do
    for i <- 0..(@bloom_hash_count - 1) do
      index = bloom_hash(key, i)
      :atomics.put(bloom, index + 1, 1)
    end

    bloom
  end

  @spec bloom_contains?(:atomics.atomics_ref(), cache_key()) :: boolean()
  defp bloom_contains?(bloom, key) do
    Enum.all?(0..(@bloom_hash_count - 1), fn i ->
      index = bloom_hash(key, i)
      :atomics.get(bloom, index + 1) == 1
    end)
  end

  @spec bloom_hash(cache_key(), non_neg_integer()) :: non_neg_integer()
  defp bloom_hash(key, seed) do
    hash = :crypto.hash(:sha256, "#{seed}:#{key}")
    <<num::unsigned-integer-size(64), _::binary>> = hash
    rem(num, @bloom_size)
  end

  @spec maybe_evict(map(), non_neg_integer()) :: map()
  defp maybe_evict(state, new_size) do
    cond do
      # Evict by count
      map_size(state.cache) >= state.max_size ->
        evict_lru(state)

      # Evict by memory
      state.current_memory + new_size > state.max_memory ->
        evict_until_fits(state, new_size)

      true ->
        state
    end
  end

  @spec evict_lru(map()) :: map()
  defp evict_lru(state) do
    case state.access_order do
      [] ->
        state

      [oldest | _rest] ->
        remove_entry(state, oldest)
        |> update_in([:stats, :evictions], &(&1 + 1))
    end
  end

  @spec evict_until_fits(map(), non_neg_integer()) :: map()
  defp evict_until_fits(state, new_size) do
    if state.current_memory + new_size <= state.max_memory do
      state
    else
      case state.access_order do
        [] ->
          state

        [oldest | _rest] ->
          new_state =
            state
            |> remove_entry(oldest)
            |> update_in([:stats, :evictions], &(&1 + 1))

          evict_until_fits(new_state, new_size)
      end
    end
  end

  @spec remove_entry(map(), cache_key()) :: map()
  defp remove_entry(state, key) do
    case Map.get(state.cache, key) do
      nil ->
        state

      entry ->
        %{
          state
          | cache: Map.delete(state.cache, key),
            access_order: List.delete(state.access_order, key),
            current_memory: max(0, state.current_memory - entry.size)
        }
    end
  end

  @spec update_access_time(map(), cache_key()) :: map()
  defp update_access_time(state, key) do
    now = DateTime.utc_now()

    %{
      state
      | cache: update_in(state.cache, [key, :accessed_at], fn _ -> now end),
        access_order: (List.delete(state.access_order, key) ++ [key])
    }
  end

  @spec expired?(cache_entry(), DateTime.t()) :: boolean()
  defp expired?(entry, now \\ DateTime.utc_now()) do
    expires_at = DateTime.add(entry.created_at, entry.ttl, :millisecond)
    DateTime.compare(now, expires_at) == :gt
  end

  @spec calculate_hit_rate(map()) :: float()
  defp calculate_hit_rate(%{hits: hits, misses: misses}) when hits + misses > 0 do
    Float.round(hits / (hits + misses) * 100, 2)
  end

  defp calculate_hit_rate(_), do: 0.0

  @spec calculate_bloom_fp_rate(map()) :: float()
  defp calculate_bloom_fp_rate(%{bloom_false_positives: fp, misses: misses}) when misses > 0 do
    Float.round(fp / misses * 100, 2)
  end

  defp calculate_bloom_fp_rate(_), do: 0.0

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.minutes(5))
  end

  @spec emit_telemetry(atom(), integer(), map()) :: :ok
  defp emit_telemetry(operation, start_time, metadata) do
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      @telemetry ++ [operation],
      %{duration: duration},
      metadata
    )
  end
end
