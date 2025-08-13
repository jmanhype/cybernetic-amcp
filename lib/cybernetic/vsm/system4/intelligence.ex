
defmodule Cybernetic.VSM.System4.Intelligence do
  use GenServer
  @moduledoc """
  S4: LLM reasoning, scenario simulation, MCP tool calls.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(state), do: {:ok, state}
  
  # Handle transport messages from in-memory transport
  def handle_cast({:transport_message, message, opts}, state) do
    # Route message to the appropriate message handler
    operation = Map.get(message, "operation", "unknown")
    meta = Map.get(opts, :meta, %{})
    
    # Process the message through the message handler
    Cybernetic.VSM.System4.MessageHandler.handle_message(operation, message, meta)
    
    {:noreply, state}
  end
  
  # Test interface - routes messages through the message handler
  def handle_message(message, meta \\ %{}) do
    operation = Map.get(message, :operation, "unknown")
    Cybernetic.VSM.System4.MessageHandler.handle_message(operation, message, meta)
  end
end
