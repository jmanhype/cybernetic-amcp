
defmodule Cybernetic.Core.MCP.Registry do
  @moduledoc """
  Registry for MCP tools/capabilities discovered at runtime (VSM-aware).
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def list(), do: GenServer.call(__MODULE__, :list)
  def register(tool, meta), do: GenServer.call(__MODULE__, {:register, tool, meta})

  def init(state), do: {:ok, state}

  def handle_call(:list, _from, state), do: {:reply, Map.keys(state), state}
  def handle_call({:register, tool, meta}, _from, state), do: {:reply, :ok, Map.put(state, tool, meta)}
end
