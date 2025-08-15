
defmodule Cybernetic.Application do
  @moduledoc """
  Boots the Cybernetic runtime mapped to VSM systems.
  """
  use Application
  require Logger

  def start(_type, _args) do
    # Initialize OpenTelemetry
    Cybernetic.Telemetry.OTEL.setup()
    Logger.info("OpenTelemetry initialized for service: cybernetic")
    
    children = [
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies, []), [name: Cybernetic.ClusterSupervisor]]},
      
      # Core Security
      Cybernetic.Core.Security.NonceBloom,
      
      # CRDT Graph
      Cybernetic.Core.CRDT.Graph,
      
      # AMQP Transport
      Cybernetic.Transport.AMQP.Connection,
      {Cybernetic.Core.Transport.AMQP.Topology, []},
      Cybernetic.Core.Transport.AMQP.Publisher,
      
      # MCP Registry  
      Cybernetic.Core.MCP.Hermes.Registry,
      
      # Goldrush Integration
      {Cybernetic.Core.Goldrush.Plugins.TelemetryAlgedonic, []},
      Cybernetic.Core.Goldrush.Bridge,
      Cybernetic.Core.Goldrush.Pipeline,
      
      # Central Aggregator (must be before S4 Bridge)
      {Cybernetic.Core.Aggregator.CentralAggregator, []},
      
      # S5 SOP Engine (must be before S4 Bridge so it can receive messages)
      {Cybernetic.VSM.System5.SOPEngine, []},
      
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
      
      # Edge WASM Validator is stateless - use Cybernetic.Edge.WASM.Validator.load/2 where needed
      
      # VSM Supervisor (includes S1-S5)
      Cybernetic.VSM.Supervisor,
      
      # Telegram Agent (S1)
      Cybernetic.VSM.System1.Agents.TelegramAgent
    ] ++ health_children()
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
  end
  
  # Add health monitoring children conditionally
  defp health_children do
    if Application.get_env(:cybernetic, :enable_health_monitoring, true) do
      [Cybernetic.Health.Supervisor]
    else
      []
    end
  end
end
