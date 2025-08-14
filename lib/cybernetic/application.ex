
defmodule Cybernetic.Application do
  @moduledoc """
  Boots the Cybernetic runtime mapped to VSM systems.
  """
  use Application
  require Logger

  def start(_type, _args) do
    children = [
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies, []), [name: Cybernetic.ClusterSupervisor]]},
      
      # Core Security
      Cybernetic.Core.Security.NonceBloom,
      
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
      
      # VSM Supervisor (includes S1-S5)
      Cybernetic.VSM.Supervisor,
      
      # Telegram Agent (S1)
      Cybernetic.VSM.System1.Agents.TelegramAgent
    ]
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
end
