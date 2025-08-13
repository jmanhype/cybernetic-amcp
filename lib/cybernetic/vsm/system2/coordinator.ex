
defmodule Cybernetic.VSM.System2.Coordinator do
  use GenServer
  @moduledoc """
  S2: Attention/coordination engine (Layer 6B analog).
  """

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state), do: {:ok, Map.put(state, :attention, %{})}

  def focus(task_id), do: GenServer.cast(__MODULE__, {:focus, task_id})

  def handle_cast({:focus, task_id}, state) do
    att = Map.update(state.attention, task_id, %{weight: 1.1, last: System.monotonic_time()}, fn a -> %{a | weight: a.weight * 1.05, last: System.monotonic_time()} end)
    {:noreply, %{state | attention: att}}
  end
  
  # Handle transport messages from in-memory transport
  def handle_cast({:transport_message, message, opts}, state) do
    # Extract operation from type field first (for routing keys), then fallback to operation field
    operation = case Map.get(message, :type) || Map.get(message, "type") do
      "vsm.s2.coordinate" -> "coordinate"
      "vsm.s2.coordination" -> "coordination"
      "vsm.s2.coordination_complete" -> "coordination_complete"
      "vsm.s2.sync" -> "sync"
      "vsm.s2.status_request" -> "status_request"
      _ ->
        # Fallback to operation field
        Map.get(message, :operation, Map.get(message, "operation", "unknown"))
    end
    
    meta = Keyword.get(opts, :meta, %{})
    
    # Process the message through the message handler
    Cybernetic.VSM.System2.MessageHandler.handle_message(operation, message, meta)
    
    {:noreply, state}
  end
  
  # Test interface - routes messages through the message handler
  def handle_message(message, meta \\ %{}) do
    # Extract operation from type field or operation field
    operation = case Map.get(message, :type) || Map.get(message, "type") do
      "vsm.s2.coordination" -> "coordination"
      "vsm.s2.coordination_complete" -> "coordination_complete"
      "vsm.s2.coordinate" -> "coordinate"
      "vsm.s2.sync" -> "sync"
      "vsm.s2.status_request" -> "status_request"
      _ ->
        # Fallback to operation field
        Map.get(message, :operation, Map.get(message, "operation", "unknown"))
    end
    
    Cybernetic.VSM.System2.MessageHandler.handle_message(operation, message, meta)
  end
end
