defmodule Cybernetic.VSM.System2.MessageHandler do
  @moduledoc """
  Message handler for VSM System 2 (Coordination).
  Handles coordination messages and inter-system communication.
  """
  require Logger

  def handle_message(operation, payload, meta) do
    Logger.debug("System2 received #{operation}: #{inspect(payload)}")
    
    case operation do
      "coordination" -> handle_coordination(payload, meta)
      "coordinate" -> handle_coordinate(payload, meta)
      "sync" -> handle_sync(payload, meta)
      "status_request" -> handle_status_request(payload, meta)
      "priority_update" -> handle_priority_update(payload, meta)
      "default" -> handle_default(payload, meta)
      _ -> 
        Logger.warning("Unknown operation for System2: #{operation}")
        {:error, :unknown_operation}
    end
  rescue
    error ->
      Logger.error("Error in System2 message handler: #{inspect(error)}")
      {:error, error}
  end

  defp handle_coordination(payload, meta) do
    # Check if action is present
    unless Map.has_key?(payload, "action") || Map.has_key?(payload, :action) do
      return {:error, :missing_action}
    end
    
    action = Map.get(payload, "action") || Map.get(payload, :action)
    Logger.info("System2: Coordination with action=#{action}")
    
    # Process based on action type
    case action do
      "coordinate" -> coordinate_systems(Map.get(payload, :systems, []), payload, meta)
      _ -> :ok
    end
    
    :ok
  end

  defp handle_coordinate(payload, meta) do
    Logger.info("System2: Coordinating systems - #{inspect(payload)}")
    
    # Send coordination messages to specified systems
    case Map.get(payload, "target_systems") do
      nil -> {:error, :no_target_systems}
      systems when is_list(systems) ->
        coordinate_systems(systems, payload, meta)
        :ok
      system ->
        coordinate_systems([system], payload, meta)
        :ok
    end
  end

  defp handle_sync(payload, meta) do
    Logger.debug("System2: Sync request - #{inspect(payload)}")
    
    # Broadcast sync to all systems
    Cybernetic.Transport.GenStageAdapter.broadcast_vsm_message(
      "sync_response", 
      %{"timestamp" => :os.system_time(:millisecond), "data" => payload},
      meta
    )
    
    :ok
  end

  defp handle_status_request(payload, meta) do
    Logger.debug("System2: Status request")
    
    # Collect status from all systems
    status = %{
      "system2" => "active",
      "coordination_active" => true,
      "timestamp" => :os.system_time(:millisecond)
    }
    
    respond_with_status(status, meta)
    :ok
  end

  defp handle_priority_update(payload, meta) do
    Logger.info("System2: Priority update - #{inspect(payload)}")
    :ok
  end

  defp handle_default(payload, meta) do
    Logger.debug("System2: Default handler - #{inspect(payload)}")
    :ok
  end

  defp coordinate_systems(systems, payload, meta) do
    action = Map.get(payload, "action", "coordinate")
    
    Enum.each(systems, fn system ->
      Cybernetic.Transport.GenStageAdapter.publish_vsm_message(
        system,
        "coordination",
        Map.put(payload, "coordinator", "system2"),
        meta
      )
    end)
  end

  defp respond_with_status(status, meta) do
    case Map.get(meta, :source_node) do
      nil -> Logger.debug("System2: No source node for status response")
      _source_node ->
        Cybernetic.Transport.GenStageAdapter.publish_vsm_message(
          :system2,
          "status_response",
          status,
          meta
        )
    end
  end
  
  defp return(value), do: value
end