defmodule Cybernetic.Application do
  @moduledoc """
  Boots the Cybernetic runtime mapped to VSM systems.
  """
  use Application
  require Logger

  def start(_type, _args) do
    # Validate critical configuration before starting
    with :ok <- validate_configuration() do
      # Initialize OpenTelemetry with error handling
      try do
        Cybernetic.Telemetry.OTEL.setup()
        Logger.info("OpenTelemetry initialized for service: cybernetic")
      rescue
        e ->
          Logger.warning("OpenTelemetry initialization failed: #{inspect(e)}")
          # Continue without OpenTelemetry for now
          :ok
      end

      children =
        [
          {Cluster.Supervisor,
           [
             Application.get_env(:libcluster, :topologies, []),
             [name: Cybernetic.ClusterSupervisor]
           ]},
          # Phoenix Edge Gateway Endpoint
          Cybernetic.Edge.Gateway.Endpoint,
          # Core Security
          Cybernetic.Core.Security.NonceBloom,
          # CRDT Graph
          Cybernetic.Core.CRDT.Graph,
          # AMQP Transport
          Cybernetic.Transport.AMQP.Connection,
          {Cybernetic.Core.Transport.AMQP.Topology, []},
          Cybernetic.Core.Transport.AMQP.Publisher,
          # Performance Optimizations
          {Cybernetic.Core.Transport.AMQP.PublisherPool, []},
          {Cybernetic.Core.CRDT.Cache, []},
          {Cybernetic.Telemetry.BatchedCollector, []},
          # MCP Registry
          Cybernetic.Core.MCP.Hermes.Registry,
          # Circuit Breaker Registry
          {Registry,
           keys: :unique, name: Cybernetic.Core.Resilience.AdaptiveCircuitBreaker.Registry},
          # Goldrush Integration
          {Cybernetic.Core.Goldrush.Plugins.TelemetryAlgedonic, []},
          Cybernetic.Core.Goldrush.Bridge,
          Cybernetic.Core.Goldrush.Pipeline,
          # Central Aggregator (must be before S4 Bridge)
          {Cybernetic.Core.Aggregator.CentralAggregator, []},
          # S5 SOP Engine (must be before S4 Bridge so it can receive messages)
          {Cybernetic.VSM.System5.SOPEngine, []},
          # S5 Policy Store
          {Cybernetic.VSM.System5.Policy, []},
          # S5 Policy Intelligence Engine
          {Cybernetic.VSM.System5.PolicyIntelligence, []},
          # S4 Intelligence Layer
          {Cybernetic.VSM.System4.LLMBridge, provider: Cybernetic.VSM.System4.Providers.Null},
          # S4 Multi-Provider Intelligence Service
          {Cybernetic.VSM.System4.Service, []},
          # S4 Memory for conversation context
          {Cybernetic.VSM.System4.Memory, []},
          # S3 Rate Limiter for budget management
          {Cybernetic.VSM.System3.RateLimiter, []},
          # Security AuthManager for MCP tools
          {Cybernetic.Security.AuthManager, []},
          # Edge WASM Validator is stateless - use Cybernetic.Edge.WASM.Validator.load/2 where needed
          # VSM Supervisor (includes S1-S5)
          Cybernetic.VSM.Supervisor,
          # Telegram Agent (S1)
          Cybernetic.VSM.System1.Agents.TelegramAgent
        ] ++ health_children() ++ telemetry_children()

      opts = [
        strategy: :one_for_one,
        name: Cybernetic.Supervisor,
        max_restarts: 10,
        max_seconds: 60
      ]

      {:ok, sup} = Supervisor.start_link(children, opts)

      # Block on MCP tools so S1-S5 workers can assume availability
      Task.start(fn ->
        case Cybernetic.Core.MCP.Hermes.Registry.await_ready(2_000) do
          :ok ->
            Logger.info("MCP Registry ready with builtin tools")

          {:error, :timeout} ->
            Logger.error("MCP registry not ready in time")
        end
      end)

      {:ok, sup}
    else
      {:error, reason} ->
        Logger.error("Configuration validation failed: #{reason}")
        {:error, reason}
    end
  end

  # Configuration validation
  defp validate_configuration do
    case Mix.env() do
      env when env in [:test, :dev] ->
        # In dev/test, just warn about missing production variables
        if System.get_env("JWT_SECRET") == "dev-secret-change-in-production" do
          Logger.info("Using default JWT_SECRET for #{env} environment")
        end

        :ok

      :prod ->
        # In production, require proper configuration
        required_env_vars = [
          "JWT_SECRET",
          "PASSWORD_SALT"
        ]

        missing =
          Enum.filter(required_env_vars, fn var ->
            case System.get_env(var) do
              nil -> true
              "" -> true
              # Default not allowed in prod
              "dev-secret-change-in-production" -> true
              _ -> false
            end
          end)

        if missing != [] do
          {:error,
           "Missing/invalid required environment variables in production: #{Enum.join(missing, ", ")}"}
        else
          # Validate JWT secret strength in production
          jwt_secret = System.get_env("JWT_SECRET")

          if String.length(jwt_secret) < 32 do
            {:error, "JWT_SECRET must be at least 32 characters in production"}
          else
            :ok
          end
        end
    end
  end

  # Add health monitoring children conditionally
  defp health_children do
    if Application.get_env(:cybernetic, :enable_health_monitoring, true) do
      [
        Cybernetic.Health.Supervisor,
        Cybernetic.Core.Resilience.CircuitBreakerAlerts
      ]
    else
      []
    end
  end

  # Add telemetry children conditionally
  defp telemetry_children do
    if Application.get_env(:cybernetic, :enable_telemetry, true) do
      [Cybernetic.Telemetry.Supervisor]
    else
      []
    end
  end
end
