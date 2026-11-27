defmodule Cybernetic.Transport.InMemory do
  @moduledoc """
  In-memory transport implementation for tests.
  Routes messages directly to VSM system GenServers without AMQP.

  Routing follows the canonical addressing scheme (coupling #6):
  a routing key addresses a VSM system by its `sN` prefix, and any
  `sN.<channel>` key is delivered to that system - the in-process
  equivalent of the AMQP `sN.#` topic binding on `cyb.commands`.
  This covers coordination keys constructed at runtime (e.g.
  `"s1.coordination"`), response keys (e.g. `"s2.sync_response"`),
  and multi-segment keys (e.g. `"s3.algedonic.pain.severe"`). The
  exchange argument is ignored, as before. Keys outside the
  canonical scheme return `{:error, :unknown_routing_key}`.

  Delivery notifies the registered test collector (if any) with
  `{:<system>_message, message}` and casts
  `{:transport_message, message, opts}` to the addressed system's
  front GenServer when it is running. System1 has no front
  GenServer (its Operational module is a supervisor and its
  MessageHandler is stateless), so S1 delivery is collector-only.
  """

  @behaviour Cybernetic.Transport.Behaviour
  require Logger

  @impl true
  def publish(_exchange, routing_key, message, opts) do
    Logger.debug("InMemory transport: #{routing_key} -> #{inspect(message)}")

    case route(routing_key) do
      {:ok, system} ->
        send_to_system(system, message, opts)

      :error ->
        Logger.warning("InMemory transport: Unknown routing key #{routing_key}")
        {:error, :unknown_routing_key}
    end
  end

  # Canonical scheme: the first dot-segment names the system
  # (s1..s5); at least one channel segment must follow.
  defp route(routing_key) when is_binary(routing_key) do
    case String.split(routing_key, ".") do
      ["s1", _channel | _rest] -> {:ok, :system1}
      ["s2", _channel | _rest] -> {:ok, :system2}
      ["s3", _channel | _rest] -> {:ok, :system3}
      ["s4", _channel | _rest] -> {:ok, :system4}
      ["s5", _channel | _rest] -> {:ok, :system5}
      _ -> :error
    end
  end

  defp route(_routing_key), do: :error

  defp send_to_system(system, message, opts) do
    # For tests, send message to test collector if present
    if test_collector = :persistent_term.get({:test_collector, __MODULE__}, nil) do
      send(test_collector, {:"#{system}_message", message})
    end

    # Also try to send to the actual system if it's running.
    # System1 has no front GenServer to cast to (see moduledoc).
    case system do
      :system2 -> cast_if_running(Cybernetic.VSM.System2.Coordinator, message, opts)
      :system3 -> cast_if_running(Cybernetic.VSM.System3.Control, message, opts)
      :system4 -> cast_if_running(Cybernetic.VSM.System4.Intelligence, message, opts)
      :system5 -> cast_if_running(Cybernetic.VSM.System5.Policy, message, opts)
      _ -> :ok
    end

    :ok
  end

  defp cast_if_running(name, message, opts) do
    if pid = Process.whereis(name) do
      GenServer.cast(pid, {:transport_message, message, opts})
    end

    :ok
  end

  @doc """
  Set the test collector process for receiving messages during tests.
  """
  def set_test_collector(collector_pid) when is_pid(collector_pid) do
    :persistent_term.put({:test_collector, __MODULE__}, collector_pid)
  end

  def set_test_collector(nil) do
    :persistent_term.erase({:test_collector, __MODULE__})
  catch
    # Key doesn't exist
    :error, :badarg -> :ok
  end
end
