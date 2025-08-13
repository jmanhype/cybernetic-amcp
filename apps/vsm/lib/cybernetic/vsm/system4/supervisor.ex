defmodule Cybernetic.VSM.System4.Supervisor do
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: Supervisor.init([Cybernetic.VSM.System4.Intelligence], strategy: :one_for_one)
end
