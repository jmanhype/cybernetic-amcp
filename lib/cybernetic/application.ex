
defmodule Cybernetic.Application do
  @moduledoc """
  Boots the Cybernetic runtime mapped to VSM systems.
  """
  use Application

  def start(_type, _args) do
    children = [
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies, []), [name: Cybernetic.ClusterSupervisor]]},
      
      # Core Security
      Cybernetic.Core.Security.NonceBloom,
      
      # AMQP Transport
      Cybernetic.Transport.AMQP.Connection,
      Cybernetic.Core.Transport.AMQP.Publisher,
      
      # MCP Registry  
      Cybernetic.Core.MCP.Hermes.Registry,
      
      # Goldrush Integration
      {Cybernetic.Core.Goldrush.Plugins.TelemetryAlgedonic, []},
      Cybernetic.Core.Goldrush.Bridge,
      
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
    Supervisor.start_link(children, opts)
  end
end
