
defmodule Cybernetic.VSM.Supervisor do
  @moduledoc """
  Root VSM supervisor: S5→S1.
  """
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    children = [
      # S5 Policy/Identity
      Cybernetic.VSM.System5.Policy,
      # S4 Intelligence
      Cybernetic.VSM.System4.Intelligence,
      # S3 Control
      Cybernetic.VSM.System3.Control,
      # S2 Coordination
      Cybernetic.VSM.System2.Coordinator,
      # S1 Operations
      Cybernetic.VSM.System1.Operational
    ]
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
