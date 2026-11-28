defmodule Cybernetic.VSM.AMQPConsumer do
  @moduledoc """
  Shared AMQP consumer for the canonical VSM queues (Axiomatic
  Design coupling #6, stage 2).

  Stage 1 canonized the addressing scheme - `sN.<channel>` keys on
  the `cyb.commands` exchange, bound `sN.#` to the queues
  `cyb.s1.ops`, `cyb.s2.coord`, `cyb.s3.control`, `cyb.s4.llm` and
  `cyb.s5.policy` - but only System4's queue had a consumer. This
  module is the receiving end for the other four queues. It is
  parameterized by queue and owning system:

      {Cybernetic.VSM.AMQPConsumer,
       queue: "cyb.s2.coord", system: :system2, name: Cybernetic.VSM.AMQPConsumer.S2}

  System4 keeps its dedicated consumer
  (`Cybernetic.VSM.System4.AMQPConsumer`), whose Telegram response
  formatting does not generalize to the other systems.

  Connection, decode and ack behaviour mirror the System4 consumer:
  connect through the shared AMQP Connection, passively check the
  queue exists (Topology declares it), ack after dispatch, reject
  undecodable payloads without requeue, and reconnect on a 5s timer
  when the channel is unavailable. A dispatch that raises is retried
  under the bounded IP-30 policy (`dispatch_with_retry/5`): the
  failure is republished with an incremented `_retries` header and
  an exponential-backoff expiration, and only once the retry count
  is exhausted is the delivery rejected without requeue, which
  dead-letters it. Dispatch itself is a public function -
  `dispatch/4` - so the routing from a decoded message to the
  owning system's entry point is testable without a broker:

    * `:system1` -> `Cybernetic.VSM.System1.MessageHandler.handle_message/3`
    * `:system2` -> `Cybernetic.VSM.System2.MessageHandler.handle_message/3`
    * `:system3` -> `Cybernetic.VSM.System3.ControlSupervisor.process_vsm_message/2`
    * `:system5` -> `Cybernetic.VSM.System5.MessageHandler.handle_message/3`

  Instances are started only when AMQP is enabled (see
  `Cybernetic.Application`); with AMQP disabled none of them exist,
  so the disabled boot never crash-loops on the absent Connection
  process.
  """

  use GenServer
  use AMQP
  require Logger

  alias Cybernetic.Core.Transport.AMQP.Connection
  alias Cybernetic.Core.Transport.RetryHelper
  alias Cybernetic.VSM.System3.ControlSupervisor

  @default_prefetch_count 10

  @systems [:system1, :system2, :system3, :system5]

  # Operation names follow each system's MessageHandler contract.
  # Routing keys not listed here fall back to the payload's own
  # "operation" field, then to the handler's "default" operation -
  # the same fallback shape System4's consumer uses.
  @operation_by_routing_key %{
    system1: %{"s1.coordination" => "coordination"},
    system2: %{
      "s2.coordinate" => "coordinate",
      "s2.coordination" => "coordination"
    },
    system5: %{}
  }

  @doc """
  Child specification. The `:name` option doubles as the child id,
  so several instances of this module can run under one supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Starts a consumer for one canonical queue.

  Required options: `:queue` (e.g. `"cyb.s2.coord"`), `:system`
  (one of `:system1`, `:system2`, `:system3`, `:system5`) and
  `:name` (registration name, unique per queue).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Routes a decoded message to the owning system's entry point.

  The handlers for System1, System2 and System5 take an operation
  name derived from the routing key or the payload (see
  `extract_operation/3`); System3 messages go to
  `Cybernetic.VSM.System3.ControlSupervisor.process_vsm_message/2`,
  which classifies them itself. Returns whatever the system's
  handler returns, or `{:error, :invalid_message}` for payloads
  that did not decode to a map.
  """
  @spec dispatch(:system1 | :system2 | :system3 | :system5, term(), String.t(), map()) ::
          term()
  def dispatch(system, message, routing_key, meta \\ %{})

  def dispatch(:system1, message, routing_key, meta) when is_map(message) do
    {operation, payload} = extract_operation(:system1, routing_key, message)

    Cybernetic.VSM.System1.MessageHandler.handle_message(
      operation,
      payload,
      handler_meta(message, routing_key, meta)
    )
  end

  def dispatch(:system2, message, routing_key, meta) when is_map(message) do
    {operation, payload} = extract_operation(:system2, routing_key, message)

    Cybernetic.VSM.System2.MessageHandler.handle_message(
      operation,
      payload,
      handler_meta(message, routing_key, meta)
    )
  end

  def dispatch(:system3, message, routing_key, _meta) when is_map(message) do
    ControlSupervisor.process_vsm_message(message, routing_key)
  end

  def dispatch(:system5, message, routing_key, meta) when is_map(message) do
    {operation, payload} = extract_operation(:system5, routing_key, message)

    Cybernetic.VSM.System5.MessageHandler.handle_message(
      operation,
      payload,
      handler_meta(message, routing_key, meta)
    )
  end

  def dispatch(_system, _message, _routing_key, _meta), do: {:error, :invalid_message}

  @doc """
  Dispatches a decoded delivery under the bounded retry policy
  (IP-30) and reports how the caller should settle the delivery.

  The dispatch runs through
  `Cybernetic.Core.Transport.RetryHelper.with_retry/4`, which counts
  attempts in the `_retries` AMQP header. On a dispatch failure the
  helper republishes the raw payload to the `cyb.commands` exchange
  under the delivery's original routing key - so the copy returns to
  this consumer's queue - with the count incremented and an
  exponential-backoff expiration, and this function returns `:ack`
  (the retry copy supersedes the original delivery). Once the count
  reaches the helper's maximum the message is poison: the helper
  does not run the dispatch at all and this function returns
  `:reject`, so the caller rejects without requeue and the message
  dead-letters - the pre-IP-30 behaviour, now bounded behind
  retries. Handler-level `{:error, _}` results are contract
  outcomes, not delivery failures (see `dispatch_safely/3`), and are
  acked without retrying.

  The `:channel` option is forwarded to the helper (production
  deliveries always pass the consumer's channel; broker-free tests
  omit it, in which case the helper skips the republish and the
  outcome mapping is unchanged).

  Phase 2 (§6): this seam also emits the reflex layer's work and
  message telemetry - [:cybernetic, :work, :finished] / :failed
  and [:amqp, :message, :processed] / :error / :replay - mapped
  from the dispatch outcome (see `emit_delivery_events/4`).
  """
  @spec dispatch_with_retry(atom(), map(), binary(), map(), keyword()) :: :ack | :reject
  def dispatch_with_retry(system, message, payload, meta, opts \\ []) do
    headers =
      meta
      |> Map.get(:headers)
      |> RetryHelper.headers_map()
      |> Map.put("_routing_key", meta.routing_key)

    # Phase 1 (IP-31): merge the sender's Lamport tick and record
    # any causal regression into the audit log. Evidence, not a
    # gate - dispatch proceeds either way.
    Cybernetic.Transport.AMQP.Causality.check_and_record(headers)

    opts =
      Keyword.merge([exchange: "cyb.commands", routing_key: meta.routing_key], opts)

    # Phase 1 (IP-35): the consume span parents to the publisher's
    # trace context carried in the delivery headers; the per-system
    # dispatch runs as its child span.
    parent_ctx =
      Cybernetic.Telemetry.OTEL.extract_context(Map.get(meta, :headers) || [])

    token = :otel_ctx.attach(parent_ctx)
    started_us = System.monotonic_time(:microsecond)

    {settlement, result} =
      try do
        Cybernetic.Telemetry.OTEL.with_span(
          "amqp.consume",
          %{routing_key: meta.routing_key},
          fn ->
            attempt = fn ->
              Cybernetic.Telemetry.OTEL.with_span(
                "vsm.dispatch",
                %{system: system, routing_key: meta.routing_key},
                fn -> dispatch_safely(system, message, meta) end
              )
            end

            result = RetryHelper.with_retry(headers, payload, attempt, opts)

            settlement =
              case result do
                {:error, :poison} -> :reject
                _other -> :ack
              end

            {settlement, result}
          end
        )
      after
        :otel_ctx.detach(token)
      end

    # Phase 2 (§6): this seam is where the reflex layer's work and
    # message events are born (see emit_delivery_events/4).
    emit_delivery_events(system, meta.routing_key, result, started_us)

    settlement
  end

  @impl true
  def init(opts) do
    queue = Keyword.fetch!(opts, :queue)
    system = Keyword.fetch!(opts, :system)

    unless system in @systems do
      raise ArgumentError, "unknown VSM system for AMQP consumer: #{inspect(system)}"
    end

    send(self(), :connect)
    {:ok, %{channel: nil, consumer_tag: nil, queue: queue, system: system}}
  end

  @impl true
  def handle_info(:connect, state) do
    case Connection.get_channel() do
      {:ok, channel} ->
        setup_queue(channel, state.queue)
        {:ok, consumer_tag} = Basic.consume(channel, state.queue)
        Basic.qos(channel, prefetch_count: @default_prefetch_count)
        Logger.info("VSM AMQP Consumer started on queue #{state.queue}")
        {:noreply, %{state | channel: channel, consumer_tag: consumer_tag}}

      {:error, reason} ->
        Logger.error("VSM AMQP Consumer (#{state.queue}) failed to connect: #{inspect(reason)}")

        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info({:basic_deliver, payload, meta}, state) do
    Logger.debug(
      "VSM Consumer #{state.queue} received message with routing key: #{meta.routing_key}"
    )

    case Jason.decode(payload) do
      {:ok, message} ->
        case dispatch_with_retry(state.system, message, payload, meta, channel: state.channel) do
          :ack ->
            Basic.ack(state.channel, meta.delivery_tag)

          :reject ->
            Logger.error(
              "VSM Consumer #{state.queue}: dispatch retries exhausted, dead-lettering"
            )

            Basic.reject(state.channel, meta.delivery_tag, requeue: false)
        end

      {:error, reason} ->
        Logger.error("VSM Consumer #{state.queue}: failed to decode message: #{inspect(reason)}")

        # Phase 2 (§6): a decode reject is a final failure, and it
        # is labeled as one at this seam (see emit_decode_events/3).
        emit_decode_events(state.system, meta.routing_key)

        Basic.reject(state.channel, meta.delivery_tag, requeue: false)
    end

    {:noreply, state}
  end

  def handle_info({:basic_consume_ok, %{consumer_tag: consumer_tag}}, state) do
    Logger.debug("VSM Consumer #{state.queue} registered: #{consumer_tag}")
    {:noreply, state}
  end

  def handle_info({:basic_cancel, _}, state) do
    Logger.warning("VSM Consumer #{state.queue} cancelled")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _, :process, _pid, reason}, state) do
    Logger.error("VSM Consumer #{state.queue} channel down: #{inspect(reason)}")
    send(self(), :connect)
    {:noreply, %{state | channel: nil}}
  end

  # Phase 2 (§6): the two consumer dispatch seams are where the
  # reflex layer's events are born. Every AMQP-driven unit of work
  # passes exactly one of the two seams (this one, or System4's
  # process_delivery/4), so coverage is total by construction and
  # durations are measured once, in one place per seam - the same
  # seams Phase 1 put OTel spans on. In-process work that never
  # crosses AMQP is not "work" for these events; stated, accepted.
  #
  # Outcome mapping, from the RetryHelper result:
  #   * completed dispatch (handler answered, including handler
  #     contract errors) -> [:amqp, :message, :processed] and
  #     [:cybernetic, :work, :finished], duration in ms (float);
  #   * a failed attempt the bounded policy will replay ->
  #     [:amqp, :message, :replay] (the republish itself happens
  #     in RetryHelper when a channel is present);
  #   * poison (retries exhausted) -> [:amqp, :message, :error]
  #     and [:cybernetic, :work, :failed], labeled :poison.
  defp emit_delivery_events(system, routing_key, result, started_us) do
    duration_ms = (System.monotonic_time(:microsecond) - started_us) / 1000
    meta = %{system: system, routing_key: routing_key}

    case result do
      {:error, :poison} ->
        :telemetry.execute([:amqp, :message, :error], %{}, Map.put(meta, :reason, :poison))

        :telemetry.execute(
          [:cybernetic, :work, :failed],
          %{},
          Map.put(meta, :reason, :poison)
        )

      {:error, _reason} ->
        :telemetry.execute([:amqp, :message, :replay], %{}, meta)

      _ok ->
        :telemetry.execute([:amqp, :message, :processed], %{duration: duration_ms}, meta)
        :telemetry.execute([:cybernetic, :work, :finished], %{duration: duration_ms}, meta)
    end

    :ok
  end

  # A payload that does not decode can never succeed on retry; it
  # is rejected at the delivery handler as a final failure, labeled
  # :decode_error so the reflex layer can tell it from poison.
  defp emit_decode_events(system, routing_key) do
    meta = %{system: system, routing_key: routing_key, reason: :decode_error}
    :telemetry.execute([:amqp, :message, :error], %{}, meta)
    :telemetry.execute([:cybernetic, :work, :failed], %{}, meta)
    :ok
  end

  defp setup_queue(channel, queue) do
    # Queue should already exist from topology setup
    case Queue.declare(channel, queue, passive: true) do
      {:ok, _} ->
        Logger.debug("Queue #{queue} exists")

      {:error, _} ->
        Logger.warning("Queue #{queue} does not exist - topology should create it")
    end
  end

  # Handler-level error tuples ({:error, :unknown_operation} and
  # friends) are contract outcomes, not delivery failures: the
  # message was delivered and the handler answered, so it is acked
  # by the caller. Only a raised/caught dispatch counts as a
  # delivery failure here.
  defp dispatch_safely(system, message, meta) do
    result = dispatch(system, message, meta.routing_key, meta)

    case result do
      {:error, reason} ->
        Logger.warning("VSM Consumer: #{system} handler rejected message: #{inspect(reason)}")

      _other ->
        :ok
    end

    {:ok, result}
  rescue
    error -> {:error, {:dispatch_raised, error}}
  catch
    kind, reason -> {:error, {:dispatch_caught, kind, reason}}
  end

  # The handler payload is the message itself, except for the
  # envelope shape System3's send_to_s2/send_to_s4 produce
  # (%{"operation" => op, "payload" => data, ...}), where the inner
  # payload is the handler's input - the same unwrap System4's
  # consumer performs.
  defp extract_operation(system, routing_key, message) do
    payload = unwrap_payload(message)

    operation =
      @operation_by_routing_key
      |> Map.get(system, %{})
      |> Map.get(routing_key) ||
        string_field(message, "operation") ||
        string_field(payload, "operation") ||
        "default"

    {operation, payload}
  end

  defp unwrap_payload(%{"payload" => payload} = message) when is_map(payload) do
    if Map.has_key?(message, "operation"), do: payload, else: message
  end

  defp unwrap_payload(message), do: message

  defp string_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  # Mirrors System4 AMQPConsumer's handler metadata: correlation id
  # and source travel in the message's "headers" sub-map (the
  # Publisher puts them there).
  defp handler_meta(message, routing_key, _meta) do
    headers = get_in(message, ["headers"]) || %{}

    %{
      correlation_id: Map.get(headers, "correlation_id"),
      routing_key: routing_key,
      source: Map.get(headers, "source", "unknown")
    }
  end
end
