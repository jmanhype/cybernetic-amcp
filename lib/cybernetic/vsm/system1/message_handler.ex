defmodule Cybernetic.VSM.System1.MessageHandler do
  @moduledoc """
  Message handler for VSM System 1 (Operational).
  Handles incoming messages from the transport layer and routes them to appropriate system components.
  """
  require Logger

  @doc """
  Handle incoming messages for System 1.
  """
  def handle_message(operation, payload, meta) do
    Logger.debug("System1 received #{operation}: #{inspect(payload)}")
    
    case operation do
      "operation" -> handle_operation(payload, meta)
      "status_update" -> handle_status_update(payload, meta)
      "resource_request" -> handle_resource_request(payload, meta)
      "coordination" -> handle_coordination(payload, meta)
      "telemetry" -> handle_telemetry(payload, meta)
      "default" -> handle_default(payload, meta)
      _ -> 
        Logger.warn("Unknown operation for System1: #{operation}")
        {:error, :unknown_operation}
    end
  rescue
    error ->
      Logger.error("Error in System1 message handler: #{inspect(error)}")
      {:error, error}
  end

  defp handle_operation(payload, meta) do
    # Handle operational tasks and workflows
    Logger.info("System1: Processing operation - #{inspect(payload)}")
    
    # Process the operation locally first
    operation_result = case Process.whereis(Cybernetic.VSM.System1.Operational) do
      nil -> 
        Logger.warn("System1 operational supervisor not found")
        {:error, :supervisor_not_found}
      pid -> 
        # Use the public handle_message interface
        Cybernetic.VSM.System1.Operational.handle_message(payload, meta)
        :ok
    end
    
    # Forward to S2 for coordination if operation is significant
    forward_to_coordination(payload, meta)
    
    # Emit telemetry for the operation
    :telemetry.execute([:vsm, :s1, :operation], %{count: 1}, payload)
    
    operation_result
  end

  defp handle_status_update(payload, meta) do
    # Handle status updates from other systems
    Logger.debug("System1: Status update from #{Map.get(meta, :source_node, 'unknown')}")
    
    # Update local state or forward to monitoring
    broadcast_status_internally(payload, meta)
    :ok
  end

  defp handle_resource_request(payload, meta) do
    # Handle resource allocation requests
    Logger.info("System1: Resource request - #{inspect(payload)}")
    
    # Process resource request and respond
    case allocate_resources(payload) do
      {:ok, allocation} ->
        respond_to_requester(allocation, meta)
        :ok
      {:error, reason} ->
        Logger.error("System1: Resource allocation failed - #{reason}")
        {:error, reason}
    end
  end

  defp handle_coordination(payload, meta) do
    # Handle coordination messages from System 2
    Logger.debug("System1: Coordination message - #{inspect(payload)}")
    
    # Process coordination instructions
    case Map.get(payload, "action") do
      "start" -> start_coordination_task(payload, meta)
      "stop" -> stop_coordination_task(payload, meta)
      "update" -> update_coordination_task(payload, meta)
      _ -> 
        Logger.warn("Unknown coordination action")
        {:error, :unknown_coordination_action}
    end
  end

  defp handle_telemetry(payload, meta) do
    # Handle telemetry data
    Logger.debug("System1: Telemetry data received")
    
    # Forward to telemetry collectors
    :telemetry.execute([:cybernetic, :vsm, :system1, :message_received], %{
      payload_size: byte_size(:erlang.term_to_binary(payload)),
      processing_time: :os.system_time(:millisecond) - Map.get(meta, :timestamp, 0)
    }, meta)
    
    :ok
  end

  defp handle_default(payload, meta) do
    # Handle default/unknown messages
    Logger.debug("System1: Default handler - #{inspect(payload)}")
    :ok
  end

  # Helper functions
  defp broadcast_status_internally(status, meta) do
    # Broadcast status to internal components
    case Process.whereis(Cybernetic.VSM.System1.StatusManager) do
      nil -> Logger.debug("System1: StatusManager not found")
      pid -> send(pid, {:status_update, status, meta})
    end
  end

  defp allocate_resources(request) do
    # Simple resource allocation logic
    case Map.get(request, "type") do
      "cpu" -> {:ok, %{allocated: Map.get(request, "amount", 1), type: "cpu"}}
      "memory" -> {:ok, %{allocated: Map.get(request, "amount", 100), type: "memory"}}
      "network" -> {:ok, %{allocated: Map.get(request, "amount", 10), type: "network"}}
      _ -> {:error, :unsupported_resource_type}
    end
  end

  defp respond_to_requester(allocation, meta) do
    # Send response back through transport
    case Map.get(meta, :source_node) do
      nil -> Logger.warn("System1: No source node for response")
      source_node ->
        response = %{
          "status" => "allocated",
          "allocation" => allocation,
          "timestamp" => :os.system_time(:millisecond)
        }
        
        # Use AMQP Publisher to send response
        Cybernetic.Core.Transport.AMQP.Publisher.publish(
          "cyb.events", 
          "s1.resource_response", 
          response,
          [source: :system1, target_node: source_node]
        )
    end
  end

  defp start_coordination_task(payload, _meta) do
    Logger.info("System1: Starting coordination task - #{Map.get(payload, "task_id", "unknown")}")
    :ok
  end

  defp stop_coordination_task(payload, _meta) do
    Logger.info("System1: Stopping coordination task - #{Map.get(payload, "task_id", "unknown")}")
    :ok
  end

  defp update_coordination_task(payload, _meta) do
    Logger.info("System1: Updating coordination task - #{Map.get(payload, "task_id", "unknown")}")
    :ok
  end
end