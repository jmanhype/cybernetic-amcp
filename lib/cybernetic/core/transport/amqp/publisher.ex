defmodule Cybernetic.Core.Transport.AMQP.Publisher do
  @moduledoc """
  Enhanced AMQP publisher with confirms, durability, and causal headers.
  """
  use GenServer
  alias AMQP.{Basic, Channel, Confirm}
  alias Cybernetic.Core.Security.NonceBloom
  require Logger

  @exchanges [
    {"cyb.events", :topic},
    {"cyb.commands", :topic},
    {"cyb.telemetry", :fanout}
  ]

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
  def publish(exchange, routing_key, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:publish, exchange, routing_key, payload, opts}, 5000)
  end

  def handle_call({:publish, exchange, routing_key, payload, opts}, _from, %{channel: nil} = state) do
    {:reply, {:error, :no_channel}, state}
  end

  def handle_call({:publish, exchange, routing_key, payload, opts}, _from, %{channel: channel} = state) do
    headers = build_headers(opts)
    message = %{
      "headers" => headers,
      "payload" => payload
    }
    
    case Jason.encode(message) do
      {:ok, json} ->
        result = Basic.publish(
          channel,
          exchange,
          routing_key,
          json,
          persistent: true,
          content_type: "application/json",
          headers: []
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
      
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp setup_exchanges(channel) do
    Enum.each(@exchanges, fn {name, type} ->
      AMQP.Exchange.declare(channel, name, type, durable: true)
      Logger.info("Declared exchange: #{name} (#{type})")
    end)

    # Setup queues
    [
      {"cyb.s1.ops", "cyb.commands", "s1.*"},
      {"cyb.s2.coord", "cyb.commands", "s2.*"},
      {"cyb.s3.control", "cyb.commands", "s3.*"},
      {"cyb.s4.llm", "cyb.commands", "s4.*"},
      {"cyb.s5.policy", "cyb.commands", "s5.*"},
      {"cyb.telemetry.q", "cyb.telemetry", "#"}
    ]
    |> Enum.each(fn {queue, exchange, routing_key} ->
      AMQP.Queue.declare(channel, queue, durable: true)
      AMQP.Queue.bind(channel, queue, exchange, routing_key: routing_key)
      Logger.debug("Bound #{queue} to #{exchange} with key #{routing_key}")
    end)
  end

  defp build_headers(opts) do
    %{
      "security" => %{
        "nonce" => NonceBloom.generate_nonce(),
        "timestamp" => System.system_time(:second)
      },
      "causal" => opts[:causal] || %{},
      "correlation_id" => opts[:correlation_id] || generate_correlation_id(),
      "source" => opts[:source] || node()
    }
  end


  defp generate_correlation_id do
    "corr_#{System.unique_integer([:positive, :monotonic])}_#{:rand.uniform(999999)}"
  end
end