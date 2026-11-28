defmodule Cybernetic.Core.Transport.AMQP.Publisher do
  @moduledoc """
  Enhanced AMQP publisher with confirms, durability, and causal headers.
  """
  use GenServer
  alias AMQP.{Basic, Confirm}
  alias Cybernetic.Core.Security.NonceBloom
  require Logger

  defp get_exchanges do
    # Define exchange types matching existing RabbitMQ setup
    [
      {"cyb.events", :topic},
      {"cyb.commands", :topic},
      # telemetry is fanout, not topic
      {"cyb.telemetry", :fanout},
      {"vsm.dlx", :fanout}
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    {:ok, %{channel: nil}, {:continue, :setup}}
  end

  def handle_continue(:setup, state) do
    case Cybernetic.Transport.AMQP.Connection.get_channel() do
      {:ok, channel} ->
        setup_exchanges(channel)
        Confirm.select(channel)
        {:noreply, %{state | channel: channel}}

      {:error, _} ->
        Process.send_after(self(), :retry_setup, 5000)
        {:noreply, state}
    end
  end

  def handle_info(:retry_setup, state) do
    handle_continue(:setup, state)
  end

  @doc """
  Publish with confirms and causal headers
  """
  @spec publish(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def publish(exchange, routing_key, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:publish, exchange, routing_key, payload, opts}, 5000)
  catch
    # The Publisher is only started when AMQP is enabled (see
    # Cybernetic.Application). Callers - e.g. System3
    # ControlSupervisor's periodic health publish - must not crash
    # in AMQP-disabled environments.
    :exit, {:noproc, _} -> {:error, :publisher_not_available}
  end

  def handle_call(
        {:publish, exchange, routing_key, payload, opts},
        _from,
        %{channel: nil} = state
      ) do
    # Try to get channel again
    case Cybernetic.Transport.AMQP.Connection.get_channel() do
      {:ok, channel} ->
        setup_exchanges(channel)
        Confirm.select(channel)
        new_state = %{state | channel: channel}
        handle_call({:publish, exchange, routing_key, payload, opts}, nil, new_state)

      {:error, _} ->
        {:reply, {:error, :no_channel}, state}
    end
  end

  def handle_call(
        {:publish, exchange, routing_key, payload, opts},
        _from,
        %{channel: channel} = state
      ) do
    headers = build_headers(opts)

    base_message = %{
      "headers" => headers,
      "payload" => payload
    }

    # Add security envelope using NonceBloom
    secured_message = NonceBloom.enrich_message(base_message, site: node())

    case Jason.encode(secured_message) do
      {:ok, json} ->
        # Phase 1 (IP-35): the publish is an OTEL span via the
        # existing Cybernetic.Telemetry.OTEL, and the span's
        # context is injected into the AMQP headers so consumers
        # can parent their spans to it.
        Cybernetic.Telemetry.OTEL.with_span(
          "amqp.publish",
          %{exchange: exchange, routing_key: routing_key},
          fn ->
            headers =
              []
              # Phase 1 (IP-31): every publish is stamped with the
              # node's Lamport tick at this single choke point.
              |> Cybernetic.Transport.AMQP.Causality.put_headers()
              |> Cybernetic.Telemetry.OTEL.inject_context()

            Basic.publish(
              channel,
              exchange,
              routing_key,
              json,
              persistent: true,
              content_type: "application/json",
              headers: headers
            )

            # Wait for confirm using AMQP.Confirm
            case Confirm.wait_for_confirms(channel, 1500) do
              true ->
                {:reply, :ok, state}

              false ->
                Logger.error("Message nack'd by broker")
                {:reply, {:error, :nack}, state}

              :timeout ->
                Logger.error("Timeout waiting for confirm")
                {:reply, {:error, :confirm_timeout}, state}
            end
          end
        )

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # The Publisher declares the exchanges it publishes to, and
  # nothing else: queues and bindings are declared exclusively by
  # Cybernetic.Core.Transport.AMQP.Topology (coupling #6
  # consolidation - single declaration site).
  defp setup_exchanges(channel) do
    Enum.each(get_exchanges(), fn {name, type} ->
      AMQP.Exchange.declare(channel, name, type, durable: true)
      Logger.info("Declared exchange: #{name} (#{type})")
    end)
  end

  defp build_headers(opts) do
    %{
      "causal" => opts[:causal] || %{},
      "correlation_id" => opts[:correlation_id] || generate_correlation_id(),
      "source" => opts[:source] || node()
    }
  end

  defp generate_correlation_id do
    "corr_#{System.unique_integer([:positive, :monotonic])}_#{:rand.uniform(999_999)}"
  end
end
