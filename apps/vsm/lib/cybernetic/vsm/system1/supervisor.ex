defmodule Cybernetic.VSM.System1.Supervisor do
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Cybernetic.VSM.System1.AgentSupervisor},
      {Registry, keys: :duplicate, name: Cybernetic.VSM.System1.Registry}
    ]
    Supervisor.init(children, strategy: :one_for_all)
  end
end
