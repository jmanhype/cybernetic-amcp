
defmodule Cybernetic.VSM.System4.Intelligence do
  use GenServer
  @moduledoc """
  S4: LLM reasoning, scenario simulation, MCP tool calls.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(state), do: {:ok, state}
  
  # Test interface - routes messages through the message handler
  def handle_message(message, meta \\ %{}) do
    operation = Map.get(message, :operation, "unknown")
    Cybernetic.VSM.System4.MessageHandler.handle_message(operation, message, meta)
  end
end
