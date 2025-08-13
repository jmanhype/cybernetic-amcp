defmodule Cybernetic.Core.MCP.Registry do
  @moduledoc """
  VSM-aware MCP tool registry. System 5 can ratify capabilities; System 2 routes requests.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts), do: {:ok, %{tools: %{}, providers: %{}}}

  @spec register_tool(String.t(), map()) :: :ok
  def register_tool(name, spec), do: GenServer.call(__MODULE__, {:register_tool, name, spec})

  def handle_call({:register_tool, name, spec}, _from, state) do
    {:reply, :ok, put_in(state, [:tools, name], spec)}
  end
end
