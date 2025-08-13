
defmodule Cybernetic.Application do
  @moduledoc """
  Boots the Cybernetic runtime mapped to VSM systems.
  """
  use Application

  def start(_type, _args) do
    children = [
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies, []), [name: Cybernetic.ClusterSupervisor]]},
      Cybernetic.Transport.AMQP.Connection,
      Cybernetic.VSM.Supervisor
    ]
    opts = [strategy: :one_for_one, name: Cybernetic.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
