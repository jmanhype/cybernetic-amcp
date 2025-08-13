defmodule Cybernetic.Core.MCP.Supervisor do
  @moduledoc """
  Supervises MCP registry, transports, and tool adapters (Hermes/MAGG).
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    children = [
      {Cybernetic.Core.MCP.Registry, []},
      {Cybernetic.Core.MCP.StdIOTransport, []}
      # Add Hermes client once dependency is wired:
      # {Cybernetic.Core.MCP.HermesClient, []}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
