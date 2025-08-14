
defmodule Cybernetic.VSM.System2.Coordinator do
  use GenServer
  @moduledoc """
  S2: Attention/coordination engine (Layer 6B analog).
  """

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    {:ok, state 
      |> Map.put(:attention, %{})
      |> Map.put(:priorities, %{})
      |> Map.put(:resource_slots, %{})
      |> Map.put(:max_slots, 8)}
  end

  def focus(task_id), do: GenServer.cast(__MODULE__, {:focus, task_id})
  
  @doc "Set priority weight for a topic (higher = more resources)"
  def set_priority(topic, weight), do: GenServer.cast(__MODULE__, {:set_priority, topic, weight})
  
  @doc "Reserve a processing slot (returns :ok | :backpressure)"
  def reserve_slot(topic), do: GenServer.call(__MODULE__, {:reserve_slot, topic})
  
  @doc "Release a processing slot"
  def release_slot(topic), do: GenServer.cast(__MODULE__, {:release_slot, topic})

  def handle_cast({:focus, task_id}, state) do
    att = Map.update(state.attention, task_id, %{weight: 1.1, last: System.monotonic_time()}, fn a -> %{a | weight: a.weight * 1.05, last: System.monotonic_time()} end)
    {:noreply, %{state | attention: att}}
  end
  
  def handle_cast({:set_priority, topic, weight}, state) do
    {:noreply, put_in(state.priorities[topic], weight)}
  end
  
  def handle_cast({:release_slot, topic}, state) do
    slots = Map.update(state.resource_slots, topic, 0, fn s -> max(s - 1, 0) end)
    {:noreply, %{state | resource_slots: slots}}
  end
  
  def handle_call({:reserve_slot, topic}, _from, state) do
    priority = Map.get(state.priorities, topic, 1.0)
    max_slots = round(state.max_slots * (priority / max(priority, 1.0)))
    current = Map.get(state.resource_slots, topic, 0)
    
    if current < max_slots do
      {:reply, :ok, put_in(state.resource_slots[topic], current + 1)}
    else
      {:reply, :backpressure, state}
    end
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
