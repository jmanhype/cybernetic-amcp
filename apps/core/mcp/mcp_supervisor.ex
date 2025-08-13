
defmodule Cybernetic.Core.MCP.Supervisor do
  @moduledoc """
  Supervises MCP client/registry/tools per your MCP directory map.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Cybernetic.Core.MCP.Registry,
      Cybernetic.Core.MCP.Client
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
