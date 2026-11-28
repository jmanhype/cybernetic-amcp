defmodule Cybernetic.VSM.System4.AMQPConsumer do
  @moduledoc """
  AMQP consumer for System 4 (Intelligence).
  Consumes messages from cyb.s4.llm queue bound to cyb.commands exchange with s4.* routing key.
  Processes messages through S4 MessageHandler and routes responses back to requesters.

  Processing failures are settled under the bounded retry policy
  (IP-30) via `process_delivery/4`, mirroring the shared VSM
  consumer: a raise during processing is republished with an
  incremented `_retries` header and an exponential-backoff
  expiration, and the delivery is rejected without requeue - which
  dead-letters it - only once the retry count is exhausted. Before
  IP-30 a raise crashed this consumer and the broker redelivered
  the message into a fresh crash, unbounded.
  """
  use GenServer
  use AMQP
  require Logger
  alias Cybernetic.Core.Transport.AMQP.Connection
  alias Cybernetic.Core.Transport.RetryHelper

  @queue "cyb.s4.llm"
  @default_prefetch_count 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    send(self(), :connect)
    {:ok, %{channel: nil, consumer_tag: nil}}
  end

  def handle_info(:connect, state) do
    case Connection.get_channel() do
      {:ok, channel} ->
        setup_queue(channel)
        {:ok, consumer_tag} = Basic.consume(channel, @queue)
        Basic.qos(channel, prefetch_count: @default_prefetch_count)
        Logger.info("S4 AMQP Consumer started on queue #{@queue}")
        {:noreply, %{state | channel: channel, consumer_tag: consumer_tag}}

      {:error, reason} ->
        Logger.error("S4 AMQP Consumer failed to connect: #{inspect(reason)}")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info({:basic_deliver, payload, meta}, state) do
    Logger.debug("S4 Consumer received message with routing key: #{meta.routing_key}")

    case Jason.decode(payload) do
      {:ok, message} ->
        case process_delivery(message, payload, meta, channel: state.channel) do
          :ack ->
            Basic.ack(state.channel, meta.delivery_tag)

          :reject ->
            Logger.error("S4 Consumer: processing retries exhausted, dead-lettering")
            Basic.reject(state.channel, meta.delivery_tag, requeue: false)
        end

      {:error, reason} ->
        Logger.error("Failed to decode message: #{inspect(reason)}")

        # Phase 2 (§6): a decode reject is a final failure, labeled
        # at this seam (see emit_decode_events/1).
        emit_decode_events(meta.routing_key)

        Basic.reject(state.channel, meta.delivery_tag, requeue: false)
    end

    {:noreply, state}
  end

  def handle_info({:basic_consume_ok, %{consumer_tag: tag}}, state) do
    Logger.debug("S4 Consumer registered: #{tag}")
    {:noreply, state}
  end

  def handle_info({:basic_cancel, _}, state) do
    Logger.warning("S4 Consumer cancelled")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _, :process, _pid, reason}, state) do
    Logger.error("S4 Consumer channel down: #{inspect(reason)}")
    send(self(), :connect)
    {:noreply, %{state | channel: nil}}
  end

  # Phase 2 (§6): the two consumer dispatch seams are where the
  # reflex layer's events are born; this is the S4 seam (the
  # shared VSM consumer's seam carries the other four systems).
  # Outcome mapping, from the RetryHelper result: completed
  # processing -> [:amqp, :message, :processed] and
  # [:cybernetic, :work, :finished] (duration in ms, float); a
  # failed attempt the bounded policy will replay ->
  # [:amqp, :message, :replay]; poison -> [:amqp, :message, :error]
  # and [:cybernetic, :work, :failed], labeled :poison.
  defp emit_delivery_events(routing_key, result, started_us) do
    duration_ms = (System.monotonic_time(:microsecond) - started_us) / 1000
    meta = %{system: :system4, routing_key: routing_key}

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
  # :decode_error.
  defp emit_decode_events(routing_key) do
    meta = %{system: :system4, routing_key: routing_key, reason: :decode_error}
    :telemetry.execute([:amqp, :message, :error], %{}, meta)
    :telemetry.execute([:cybernetic, :work, :failed], %{}, meta)
    :ok
  end

  defp setup_queue(channel) do
    # Queue should already exist from topology setup
    case Queue.declare(channel, @queue, passive: true) do
      {:ok, _} ->
        Logger.debug("Queue #{@queue} exists")

      {:error, _} ->
        Logger.warning("Queue #{@queue} does not exist - topology should create it")
    end
  end

  @doc """
  Processes a decoded delivery under the bounded retry policy
  (IP-30) and reports how the caller should settle the delivery.

  The processing runs through
  `Cybernetic.Core.Transport.RetryHelper.with_retry/4`, which counts
  attempts in the `_retries` AMQP header. A raise during processing
  republishes the raw payload to the `cyb.commands` exchange under
  the delivery's original routing key - so the copy returns to this
  consumer's queue - with the count incremented and an
  exponential-backoff expiration, and this function returns `:ack`.
  Once the count reaches the helper's maximum the message is
  poison: the helper does not run the processing at all and this
  function returns `:reject`, so the caller rejects without requeue
  and the message dead-letters. Handler `{:error, _}` results are
  formatted into the response inside `process_message/3` and remain
  acked contract outcomes, as before.

  The `:channel` option is forwarded to the helper (production
  deliveries always pass the consumer's channel; broker-free tests
  omit it, in which case the helper skips the republish and the
  outcome mapping is unchanged).
  """
  @spec process_delivery(map(), binary(), map(), keyword()) :: :ack | :reject
  def process_delivery(message, payload, meta, opts \\ []) do
    headers =
      meta
      |> Map.get(:headers)
      |> RetryHelper.headers_map()
      |> Map.put("_routing_key", meta.routing_key)

    # Phase 1 (IP-31): merge the sender's Lamport tick and record
    # any causal regression into the audit log. Evidence, not a
    # gate - processing proceeds either way.
    Cybernetic.Transport.AMQP.Causality.check_and_record(headers)

    opts =
      Keyword.merge([exchange: "cyb.commands", routing_key: meta.routing_key], opts)

    # Phase 1 (IP-35): consume span parented to the publisher's
    # trace context; the S4 processing runs as its child span.
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
                %{system: :system4, routing_key: meta.routing_key},
                fn ->
                  try do
                    process_message(message, meta, %{})
                    :ok
                  rescue
                    error -> {:error, {:processing_raised, error}}
                  catch
                    kind, reason -> {:error, {:processing_caught, kind, reason}}
                  end
                end
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
    # message events are born for S4 deliveries (see
    # emit_delivery_events/3).
    emit_delivery_events(meta.routing_key, result, started_us)

    settlement
  end

  defp process_message(message, meta, _state) do
    # Extract correlation_id from headers (Publisher puts it there)
    headers = get_in(message, ["headers"]) || %{}
    correlation_id = Map.get(headers, "correlation_id")
    source = Map.get(headers, "source", "unknown")

    # Extract operation from routing key or message payload
    operation = extract_operation(meta.routing_key, message)

    # Extract payload (remove envelope if present)
    payload = Map.get(message, "payload", message)

    # Build metadata for handler
    handler_meta = %{
      correlation_id: correlation_id,
      routing_key: meta.routing_key,
      source: source
    }

    # Process through S4 MessageHandler
    result =
      Cybernetic.VSM.System4.MessageHandler.handle_message(operation, payload, handler_meta)

    # Send response if correlation_id present (Telegram request)
    if correlation_id do
      send_telegram_response(correlation_id, format_result(result))
    end

    # Emit telemetry for message processing
    :telemetry.execute([:s4, :amqp, :processed], %{count: 1}, %{
      operation: operation,
      routing_key: meta.routing_key,
      correlation_id: correlation_id,
      source: source
    })

    Logger.debug("S4 processed #{operation} for correlation_id: #{correlation_id}")
  end

  def extract_operation("s4.reason", _message), do: "intelligence"
  def extract_operation("s4.analyze", _message), do: "analyze"
  def extract_operation("s4.learn", _message), do: "learn"
  def extract_operation("s4.predict", _message), do: "predict"

  def extract_operation(_routing_key, message) do
    # Fallback to operation field in message
    Map.get(message, "operation", "intelligence")
  end

  defp send_telegram_response(correlation_id, response) do
    try do
      send(Cybernetic.VSM.System1.Agents.TelegramAgent, {:s4_response, correlation_id, response})
      Logger.debug("Sent S4 response to TelegramAgent for correlation_id: #{correlation_id}")
    catch
      :exit, {:noproc, _} ->
        Logger.warning("TelegramAgent not available, cannot send response")

      kind, reason ->
        Logger.error("Failed to send response to TelegramAgent: #{kind}: #{inspect(reason)}")
    end
  end

  def format_result(:ok) do
    %{"result" => "Request processed successfully"}
  end

  def format_result({:ok, result}) when is_map(result) do
    # Convert result map to response format
    case Map.get(result, "type") do
      "vsm.s4.analysis_complete" ->
        analysis_type = Map.get(result, "analysis_type", "analysis")
        health_score = Map.get(result, "health_score", 0.0)
        recommendations = Map.get(result, "recommendations", [])

        response_text = """
        Analysis: #{analysis_type}
        Health Score: #{Float.round(health_score * 100, 1)}%
        Recommendations: #{Enum.join(recommendations, ", ")}
        """

        %{"result" => response_text}

      _type ->
        %{"result" => inspect(result)}
    end
  end

  def format_result({:error, reason}) do
    %{"error" => "Processing failed: #{inspect(reason)}"}
  end

  def format_result(other), do: %{"result" => inspect(other)}
end
