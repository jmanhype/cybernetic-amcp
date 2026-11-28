defmodule Cybernetic.Transport.AMQP.Causality do
  @moduledoc """
  Causal-ordering headers and violation detection (Phase 1, IP-31).

  Publishers stamp each message at the publish choke point with
  typed AMQP headers:

    * `x-lamport` (:signedint) - the sender's Lamport tick
      (`Cybernetic.Transport.AMQP.LamportClock`)
    * `x-node` (:longstr) - the sending node

  Consumers merge the received value into their local clock and
  check it against the last value seen from that node. A received
  value strictly below the last seen from the same node is a causal
  regression: it is recorded into the audit log as a
  `:causality_violation` event (the IP-27 substrate) and emitted as
  telemetry. Processing continues - the record is evidence, not a
  gate.

  Replaced in Phase 1: the old stamp carried wall-clock time in
  `x-lamport` (not a Lamport value - two nodes' wall clocks cannot
  order each other's events) and an opaque `:erlang.term_to_binary`
  blob in `x-clock` that nothing in the system could read. Both are
  gone; nothing consumed either.
  """

  alias Cybernetic.Transport.AMQP.LamportClock

  @doc """
  Stamps causality headers onto an AMQP header list: ticks the
  local Lamport clock and appends `x-lamport` / `x-node` as typed
  AMQP header tuples.
  """
  @spec put_headers(list(), String.t()) :: list()
  def put_headers(headers \\ [], node_id \\ to_string(node())) do
    headers ++
      [
        {"x-lamport", :signedint, LamportClock.tick()},
        {"x-node", :longstr, node_id}
      ]
  end

  @doc """
  Checks a received message's causality headers (a plain map, as
  produced by `RetryHelper.headers_map/1`).

  Unstamped traffic (no `x-lamport` / `x-node`) is not a violation:
  returns `:ok`. A stamped regression records the audit event and
  telemetry, and returns `{:violation, details}`; callers continue
  processing either way.
  """
  @spec check_and_record(map()) :: :ok | {:violation, map()}
  def check_and_record(headers) when is_map(headers) do
    with received when is_integer(received) <- headers["x-lamport"],
         node when is_binary(node) <- headers["x-node"] do
      case LamportClock.observe(node, received) do
        {:violation, details} ->
          Cybernetic.Audit.Log.record(:causality_violation, details)

          :telemetry.execute(
            [:cybernetic, :transport, :causality_violation],
            %{count: 1},
            details
          )

          {:violation, details}

        :ok ->
          :ok
      end
    else
      _unstamped -> :ok
    end
  end
end
