defmodule Cybernetic.Core.MCP.StdIOTransport do
  @moduledoc """
  Minimal MCP stdio transport (placeholder).
  """
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_), do: {:ok, %{}}
end
