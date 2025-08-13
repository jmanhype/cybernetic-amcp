defmodule Cybernetic.Core.Transport.AMQP.Consumer do
  @moduledoc """
  AMQP consumer with replay protection using nonce bloom filter.
  Ensures exactly-once message processing with cryptographic guarantees.
  """
  use GenServer
  use AMQP
  require Logger
  alias Cybernetic.Core.Security.NonceBloom
  alias Cybernetic.Core.Transport.AMQP.Connection

  @exchange "cybernetic.events"
  @queue "cybernetic.consumer"
  @prefetch_count 10

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    send(self(), :connect)
    {:ok, %{channel: nil, consumer_tag: nil, opts: opts}}
  end

  def handle_info(:connect, state) do
    case Connection.get_channel() do
      {:ok, channel} ->
        setup_queue(channel)
        {:ok, consumer_tag} = Basic.consume(channel, @queue)
        Basic.qos(channel, prefetch_count: @prefetch_count)
        {:noreply, %{state | channel: channel, consumer_tag: consumer_tag}}
      
      {:error, reason} ->
        Logger.error("Failed to connect: #{inspect(reason)}")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info({:basic_deliver, payload, meta}, state) do
    with {:ok, message} <- Jason.decode(payload),
         {:ok, validated} <- validate_and_process(message, meta) do
      Basic.ack(state.channel, meta.delivery_tag)
      :telemetry.execute([:amqp, :message, :processed], %{count: 1}, meta)
    else
      {:error, :replay_detected} ->
        Logger.warn("Replay attack detected, rejecting message")
        Basic.reject(state.channel, meta.delivery_tag, requeue: false)
        :telemetry.execute([:amqp, :message, :replay], %{count: 1}, meta)
      
      {:error, reason} ->
        Logger.error("Failed to process message: #{inspect(reason)}")
        Basic.reject(state.channel, meta.delivery_tag, requeue: true)
        :telemetry.execute([:amqp, :message, :error], %{count: 1}, meta)
    end
    
    {:noreply, state}
  end

  def handle_info({:basic_consume_ok, %{consumer_tag: consumer_tag}}, state) do
    Logger.info("Consumer registered: #{consumer_tag}")
    {:noreply, state}
  end

  def handle_info({:basic_cancel, _}, state) do
    Logger.warn("Consumer cancelled")
    {:stop, :normal, state}
  end

  def handle_info({:basic_cancel_ok, _}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, _pid, reason}, state) do
    Logger.error("Channel down: #{inspect(reason)}")
    send(self(), :connect)
    {:noreply, %{state | channel: nil}}
  end

  defp setup_queue(channel) do
    {:ok, _} = Queue.declare(channel, @queue, 
      durable: true,
      arguments: [
        {"x-message-ttl", :long, 86_400_000},
        {"x-dead-letter-exchange", :longstr, "cybernetic.dlx"}
      ]
    )
    
    :ok = Exchange.declare(channel, @exchange, :topic, durable: true)
    :ok = Queue.bind(channel, @queue, @exchange, routing_key: "#")
  end

  defp validate_and_process(message, meta) do
    # Extract nonce from message headers or body
    nonce = message["nonce"] || get_header(meta, "x-nonce")
    
    # Validate nonce hasn't been seen before
    case NonceBloom.validate_message(nonce, message) do
      {:ok, _validated} ->
        # Process the message based on type
        process_by_type(message, meta)
        
      {:error, :replay} ->
        {:error, :replay_detected}
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_by_type(%{"type" => "vsm." <> system} = message, meta) do
    # Route to appropriate VSM system
    vsm_module = String.to_atom("Elixir.Cybernetic.Apps.VSM.System#{String.upcase(system)}")
    if Code.ensure_loaded?(vsm_module) do
      apply(vsm_module, :handle_message, [message, meta])
    else
      Logger.warn("Unknown VSM system: #{system}")
      {:error, :unknown_system}
    end
  end

  defp process_by_type(%{"type" => "telemetry"} = message, _meta) do
    # Forward to telemetry system
    :telemetry.execute(
      [:cybernetic, :event],
      message["metrics"] || %{},
      message["metadata"] || %{}
    )
    {:ok, :telemetry_processed}
  end

  defp process_by_type(%{"type" => "mcp"} = message, _meta) do
    # Forward to MCP handler
    Cybernetic.Core.MCP.Handler.process(message)
  end

  defp process_by_type(message, _meta) do
    Logger.debug("Unhandled message type: #{inspect(message)}")
    {:ok, :unhandled}
  end

  defp get_header(meta, key) do
    case meta.headers do
      headers when is_list(headers) ->
        Enum.find_value(headers, fn
          {^key, _, value} -> value
          _ -> nil
        end)
      _ -> nil
    end
  end
end