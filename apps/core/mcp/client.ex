
defmodule Cybernetic.Core.MCP.Client do
  @moduledoc """
  Hermes MCP client adapter. Handles stdio/websocket transports, tool calls, and prompts.
  """
  use GenServer
  require Logger

  # NOTE: This module expects hermes_mcp as a dependency.
  # Swap to the correct Hermes client module functions as needed.
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    # Bootstrap: discover tools from configured MCP server(s)
    Process.send_after(self(), :discover, 0)
    {:ok, %{sessions: %{}, tools: %{}}}
  end

  def handle_info(:discover, state) do
    # Pseudocode: replace with Hermes.MCP discovery once configured
    # {:ok, tools} = HermesMCP.discover()
    tools = []
    Enum.each(tools, fn t -> Cybernetic.Core.MCP.Registry.register(t.name, t) end)
    {:noreply, %{state | tools: Map.new(tools, &{&1.name, &1})}}
  end

  def call_tool(tool, params), do:
    GenServer.call(__MODULE__, {:call_tool, tool, params}, 30_000)

  def handle_call({:call_tool, tool, params}, _from, state) do
    # Pseudocode call into Hermes
    # result = HermesMCP.call(tool, params)
    result = {:ok, %{tool: tool, echo: params}}
    {:reply, result, state}
  end
end
