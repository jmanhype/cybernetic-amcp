defmodule Cybernetic.Core.Transport.AMQP.Topology do
  @moduledoc """
  AMQP topology setup for Cybernetic framework.
  Defines durable exchanges, queues, and bindings for VSM systems.
  """

  use GenServer
  require Logger
  alias AMQP.{Exchange, Queue}
  alias Cybernetic.Core.Transport.AMQP.Connection

  # @exchanges attribute was unused - commented out for now
  # Static exchanges are managed in config/runtime.exs instead
  # @exchanges [
  #   # Core event bus for all systems
  #   {:events, :topic, durable: true, auto_delete: false},
  #   
  #   # Telemetry data from all components
  #   {:telemetry, :topic, durable: true, auto_delete: false},
  #   
  #   # MCP tool invocations and results
  #   {:mcp, :direct, durable: true, auto_delete: false},
  #   
  #   # VSM inter-system communication
  #   {:vsm, :topic, durable: true, auto_delete: false},
  #   
  #   # Priority messages (algedonic channel)
  #   {:priority, :direct, durable: true, auto_delete: false},
  #   
  #   # Dead letter exchange for failed messages (use vsm.dlx to match existing)
  #   {:dlx, :fanout, durable: true, auto_delete: false},
  #   {"vsm.dlx", :fanout, durable: true, auto_delete: false}
  # ]

  @queues [
    # VSM System queues - match existing configuration
    {"vsm.s1.operations",
     durable: true,
     arguments: [
       {"x-dead-letter-exchange", :longstr, "vsm.dlx"},
       {"x-max-length", :long, 10000},
       {"x-message-ttl", :long, 300_000},
       {"x-overflow", :longstr, "drop-head"}
     ]},
    {"vsm.s2.coordination",
     durable: true,
     arguments: [
       {"x-dead-letter-exchange", :longstr, "vsm.dlx"},
       {"x-max-length", :long, 5000},
       {"x-message-ttl", :long, 600_000},
       {"x-single-active-consumer", :bool, true}
     ]},
    {"vsm.s3.control",
     durable: true,
     arguments: [
       {"x-dead-letter-exchange", :longstr, "vsm.dlx"},
       {"x-max-length", :long, 3000},
       {"x-max-priority", :byte, 10},
       {"x-message-ttl", :long, 900_000}
     ]},
    {"vsm.s4.intelligence",
     durable: true,
     arguments: [
       {"x-dead-letter-exchange", :longstr, "vsm.dlx"},
       {"x-max-length", :long, 20000},
       {"x-message-ttl", :long, 3_600_000}
     ]},
    {"vsm.s5.policy",
     durable: true,
     arguments: [
       {"x-dead-letter-exchange", :longstr, "vsm.dlx"},
       {"x-max-length", :long, 1000},
       {"x-message-ttl", :long, 86_400_000}
     ]},

    # MCP queues
    {"mcp.requests", durable: true},
    {"mcp.responses", durable: true},

    # Telemetry aggregation
    {"telemetry.metrics", durable: true},
    {"telemetry.logs", durable: true},

    # Event processing
    {"events.stream", durable: true},

    # Priority/algedonic messages
    {"priority.alerts", durable: true, arguments: [{"x-priority", :byte, 10}]},

    # Dead letter queue
    {"dlq", durable: true},

    # Retry queue with TTL and dead-letter back to main exchange
    {"cyb.events.retry",
     durable: true,
     arguments: [
       {"x-dead-letter-exchange", :longstr, "cyb.events"},
       # 15 second retry delay
       {"x-message-ttl", :signedint, 15000}
     ]},

    # Failed messages after max retries
    {"cyb.events.failed", durable: true}
  ]

  @bindings [
    # VSM bindings to event exchange
    {"cyb.events", "vsm.s1.operations", "vsm.s1.*"},
    {"cyb.events", "vsm.s2.coordination", "vsm.s2.*"},
    {"cyb.events", "vsm.s3.control", "vsm.s3.*"},
    {"cyb.events", "vsm.s4.intelligence", "vsm.s4.*"},
    {"cyb.events", "vsm.s5.policy", "vsm.s5.*"},

    # VSM internal communication - using individual system exchanges
    {"cyb.vsm.s1", "vsm.s1.operations", "s1.#"},
    {"cyb.vsm.s2", "vsm.s2.coordination", "s2.#"},
    {"cyb.vsm.s3", "vsm.s3.control", "s3.#"},
    {"cyb.vsm.s4", "vsm.s4.intelligence", "s4.#"},
    {"cyb.vsm.s5", "vsm.s5.policy", "s5.#"},

    # MCP bindings - use cyb.mcp.tools exchange
    {"cyb.mcp.tools", "mcp.requests", "request"},
    {"cyb.mcp.tools", "mcp.responses", "response"},

    # Telemetry bindings
    {"cyb.telemetry", "telemetry.metrics", "metrics.#"},
    {"cyb.telemetry", "telemetry.logs", "logs.#"},

    # Event stream binding
    {"cyb.events", "events.stream", "#"},

    # Dead letter bindings
    {"vsm.dlx", "dlq", ""},

    # Retry queue binding to DLX
    {"vsm.dlx", "cyb.events.retry", "retry"}
  ]

  # GenServer callbacks

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Setup topology on connection
    case Connection.get_channel() do
      {:ok, channel} ->
        case setup(channel) do
          :ok -> {:ok, %{channel: channel}}
          error -> {:stop, error}
        end

      {:error, reason} ->
        Logger.warning("Failed to get AMQP channel for topology setup: #{inspect(reason)}")
        {:ok, %{channel: nil}}
    end
  end

  @doc """
  Set up the complete AMQP topology - legacy entry point
  """
  def declare(chan) do
    setup(chan)
  end

  @doc """
  Set up the complete AMQP topology
  """
  def setup(channel) do
    Logger.info("Setting up AMQP topology...")

    with :ok <- declare_exchanges(channel),
         :ok <- declare_queues(channel),
         :ok <- create_bindings(channel) do
      Logger.info("AMQP topology setup complete")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to set up AMQP topology: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Declare all exchanges using standardized config
  """
  def declare_exchanges(channel) do
    exchanges = Application.get_env(:cybernetic, :amqp)[:exchanges] || %{}

    # Exchange types - telemetry is fanout, rest are topic
    exchange_types = %{
      telemetry: :fanout,
      events: :topic,
      commands: :topic,
      mcp_tools: :topic,
      s1: :topic,
      vsm: :topic
    }

    for {key, exchange_name} <- exchanges do
      type = Map.get(exchange_types, key, :topic)

      case Exchange.declare(channel, exchange_name, type, durable: true, auto_delete: false) do
        :ok ->
          Logger.debug("Declared exchange: #{key}=#{exchange_name} (#{type})")
          :ok

        {:error, {:resource_locked, _}} ->
          Logger.debug("Exchange already exists: #{exchange_name}")
          :ok

        {:error, reason} = error ->
          Logger.error("Failed to declare exchange #{key}=#{exchange_name}: #{inspect(reason)}")
          error
      end
    end

    :ok
  end

  @doc """
  Declare all queues
  """
  def declare_queues(channel) do
    Enum.reduce_while(@queues, :ok, fn queue_spec, _acc ->
      {name, opts} =
        case queue_spec do
          {n, opts} -> {n, opts}
          n -> {n, []}
        end

      case Queue.declare(channel, name, opts) do
        {:ok, _} ->
          Logger.debug("Declared queue: #{name}")
          {:cont, :ok}

        {:error, {:resource_locked, _}} ->
          # Queue exists with different args, try passive declare
          case Queue.declare(channel, name, passive: true) do
            {:ok, _} ->
              Logger.debug("Queue already exists: #{name}")
              {:cont, :ok}

            _error ->
              Logger.warning("Queue exists with different args: #{name}")
              # Continue anyway since queue exists
              {:cont, :ok}
          end

        {:error, reason} = error ->
          Logger.error("Failed to declare queue #{name}: #{inspect(reason)}")
          {:halt, error}
      end
    end)
  end

  @doc """
  Create all bindings between exchanges and queues
  """
  def create_bindings(channel) do
    Enum.reduce_while(@bindings, :ok, fn {exchange, queue, routing_key}, _acc ->
      case Queue.bind(channel, queue, exchange, routing_key: routing_key) do
        :ok ->
          Logger.debug("Bound #{queue} to #{exchange} with key: #{routing_key}")
          {:cont, :ok}

        {:error, reason} = error ->
          Logger.error("Failed to bind #{queue} to #{exchange}: #{inspect(reason)}")
          {:halt, error}
      end
    end)
  end

  @doc """
  Get exchange name for a given component from config
  """
  def exchange_for(key) when is_atom(key) do
    exchanges = Application.get_env(:cybernetic, :amqp)[:exchanges] || %{}
    Map.get(exchanges, key, "cyb.events")
  end

  @doc """
  Get queue name for a VSM system
  """
  def queue_for_system(1), do: "vsm.s1.operations"
  def queue_for_system(2), do: "vsm.s2.coordination"
  def queue_for_system(3), do: "vsm.s3.control"
  def queue_for_system(4), do: "vsm.s4.intelligence"
  def queue_for_system(5), do: "vsm.s5.policy"
  def queue_for_system(_), do: "events.stream"

  @doc """
  Get routing key for VSM system messages
  """
  def routing_key_for_system(system_num, action \\ "update") do
    "s#{system_num}.#{action}"
  end
end
