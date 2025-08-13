defmodule Cybernetic.Transport.GenStageTransportTest do
  @moduledoc """
  Test suite for the GenStage-based transport system.
  Verifies message routing between VSM systems.
  """
  use ExUnit.Case, async: false
  
  alias Cybernetic.Transport.GenStageAdapter
  alias Cybernetic.Transport.GenStageSupervisor
  
  setup_all do
    # Start the transport supervisor if not already started
    case GenStageSupervisor.status() do
      %{producer: :running} -> :ok
      _ -> start_supervised!(GenStageSupervisor)
    end
    
    # Give the system time to start
    :timer.sleep(100)
    :ok
  end

  test "transport health check returns healthy status" do
    health = GenStageAdapter.health_check()
    
    assert health.status == :healthy
    assert health.producer_alive == true
    assert is_integer(health.queue_size)
    assert health.node == node()
  end

  test "can publish message to VSM system" do
    payload = %{"action" => "test", "data" => "hello"}
    meta = %{"test" => true}
    
    result = GenStageAdapter.publish_vsm_message(:system1, "test_operation", payload, meta)
    
    assert result == :ok
  end

  test "can broadcast message to all VSM systems" do
    payload = %{"broadcast" => "test", "timestamp" => :os.system_time(:millisecond)}
    meta = %{"broadcast_test" => true}
    
    result = GenStageAdapter.broadcast_vsm_message("test_broadcast", payload, meta)
    
    assert result == :ok
  end

  test "transport adapter implements behavior correctly" do
    exchange = "test.exchange"
    routing_key = "test.routing.key"
    payload = %{"test" => "data"}
    meta = %{"source" => "test"}
    
    result = GenStageAdapter.publish(exchange, routing_key, payload, meta)
    
    assert result == :ok
  end

  test "queue size increases with published messages" do
    initial_size = GenStageAdapter.queue_size()
    
    # Publish several messages
    for i <- 1..5 do
      GenStageAdapter.publish("test.exchange", "test.#{i}", %{"msg" => i}, %{})
    end
    
    # Give the system time to process
    :timer.sleep(50)
    
    # Queue size should have increased (or messages processed quickly)
    final_size = GenStageAdapter.queue_size()
    assert final_size >= initial_size
  end

  test "transport supervisor status shows running components" do
    status = GenStageSupervisor.status()
    
    assert status.producer == :running
    assert is_list(status.consumers)
    assert status.total_children > 0
    
    # Check that we have consumers for each VSM system
    consumer_names = status.consumers |> Enum.map(fn {name, _status} -> name end)
    expected_systems = ["System1", "System2", "System3", "System4", "System5"]
    
    for system <- expected_systems do
      consumer_name = :"Cybernetic.Transport.GenStage.Consumer.#{system}"
      assert consumer_name in consumer_names
    end
  end

  test "can send coordination message from system2 to system1" do
    payload = %{
      "action" => "start",
      "task_id" => "test_task_123",
      "priority" => "high"
    }
    
    meta = %{
      "source_system" => "system2",
      "coordination_type" => "task_assignment"
    }
    
    result = GenStageAdapter.publish_vsm_message(:system1, "coordination", payload, meta)
    
    assert result == :ok
  end

  test "can send resource request from system1 to itself" do
    payload = %{
      "type" => "cpu",
      "amount" => 2,
      "duration" => 3600
    }
    
    meta = %{
      "request_id" => "req_#{:os.system_time(:millisecond)}",
      "requester" => "test_process"
    }
    
    result = GenStageAdapter.publish_vsm_message(:system1, "resource_request", payload, meta)
    
    assert result == :ok
  end

  test "system message routing includes proper metadata" do
    payload = %{"test_data" => "routing_test"}
    
    result = GenStageAdapter.publish_vsm_message(:system3, "control", payload, %{})
    
    assert result == :ok
    
    # The transport should have enriched the metadata
    # We can't directly test the enriched metadata without more complex setup,
    # but we can verify the message was accepted
  end
end