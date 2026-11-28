defmodule Cybernetic.Transport.AMQP.LamportClock do
  @moduledoc """
  The node's Lamport clock for the AMQP transport (Phase 1, IP-31).

  A Lamport clock is the honest minimum for causal ordering: a
  per-node counter that ticks on every local event and merges on
  receipt (`counter = max(counter, received) + 1` discipline on the
  receive side). It establishes happens-before where it exists and
  claims nothing stronger - no vector clock, no total order, no
  synchronized wall time.

  The counter lives in an `:atomics` ref so the publish path can
  tick without a GenServer call per message; the owning GenServer
  holds the receive-side bookkeeping (last value seen per node,
  used by `Cybernetic.Transport.AMQP.Causality` to detect causal
  regressions). The process is started with the transport children
  (see `Cybernetic.Application`).

  A restarted clock resets its counter: peers may then see an
  apparent regression from this node. That is an accepted,
  documented limit of this phase - the violation record it
  produces is evidence with a known false-positive source, not a
  gate.
  """

  use GenServer
  require Logger

  @persistent_key {__MODULE__, :counter_ref}

  # ========== CLIENT API ==========

  @doc """
  Child specification (started with the AMQP transport children).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Starts the clock process and its counter.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ticks the local counter and returns the new value. Safe to call
  when the clock process is not running (returns a monotonic
  fallback), so the publish path never crashes on the clock.
  """
  @spec tick() :: non_neg_integer()
  def tick do
    case counter_ref() do
      nil -> :erlang.unique_integer([:monotonic, :positive])
      ref -> :atomics.add_get(ref, 1, 1)
    end
  end

  @doc """
  Returns the current counter value without ticking (0 when the
  clock is not running).
  """
  @spec now() :: non_neg_integer()
  def now do
    case counter_ref() do
      nil -> 0
      ref -> :atomics.get(ref, 1)
    end
  end

  @doc """
  Merges a received value: the local counter advances past it.
  Returns the new local value.
  """
  @spec merge(non_neg_integer()) :: non_neg_integer()
  def merge(received) when is_integer(received) and received >= 0 do
    case counter_ref() do
      nil ->
        received

      ref ->
        current = :atomics.get(ref, 1)

        if received > current do
          :atomics.put(ref, 1, received)
          received
        else
          current
        end
    end
  end

  @doc """
  Observes a value received from `node`: merges it locally and
  reports whether it regresses against the last value seen from
  that node.

  Returns `:ok` or `{:violation, %{node: node, expected_after:
  last_seen, received: received}}`. Returns `:ok` when the clock
  process is not running (no bookkeeping, no claims).
  """
  @spec observe(String.t(), non_neg_integer()) ::
          :ok | {:violation, map()}
  def observe(node, received) when is_binary(node) and is_integer(received) do
    merge(received)

    GenServer.call(__MODULE__, {:observe, node, received})
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Returns the last value seen from `node`, or nil.
  """
  @spec last_seen(String.t()) :: non_neg_integer() | nil
  def last_seen(node) do
    GenServer.call(__MODULE__, {:last_seen, node})
  catch
    :exit, {:noproc, _} -> nil
  end

  defp counter_ref do
    :persistent_term.get(@persistent_key, nil)
  end

  # ========== GENSERVER CALLBACKS ==========

  @impl true
  def init(_opts) do
    ref = :atomics.new(1, signed: false)
    :persistent_term.put(@persistent_key, ref)
    {:ok, %{seen: %{}}}
  end

  @impl true
  def handle_call({:observe, node, received}, _from, state) do
    case Map.get(state.seen, node) do
      last when is_integer(last) and received < last ->
        {:reply, {:violation, %{node: node, expected_after: last, received: received}}, state}

      _other ->
        {:reply, :ok, %{state | seen: Map.put(state.seen, node, received)}}
    end
  end

  def handle_call({:last_seen, node}, _from, state) do
    {:reply, Map.get(state.seen, node), state}
  end

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase(@persistent_key)
    :ok
  end
end
