#!/usr/bin/env elixir

# Simple test script to verify transport functionality
Mix.install([])

# Start the application
:application.ensure_all_started(:cybernetic)

# Give the system time to start
:timer.sleep(1000)

# Test the transport system
alias Cybernetic.Core.Transport.AMQP.Publisher

IO.puts("=== Cybernetic Transport System Test ===")

# Check supervisor status
status = GenStageSupervisor.status()
IO.puts("Transport Supervisor Status:")
IO.inspect(status, pretty: true)

# Check transport health
health = GenStageAdapter.health_check()
IO.puts("\nTransport Health Check:")
IO.inspect(health, pretty: true)

# Test message publishing
IO.puts("\n=== Testing Message Publishing ===")

# Test 1: Simple VSM message
result1 = GenStageAdapter.publish_vsm_message(:system1, "test_operation", %{"data" => "test"}, %{})
IO.puts("System1 message result: #{inspect(result1)}")

# Test 2: Coordination message
result2 = GenStageAdapter.publish_vsm_message(:system2, "coordinate", %{"action" => "start", "target_systems" => [:system1, :system3]}, %{})
IO.puts("System2 coordination result: #{inspect(result2)}")

# Test 3: Broadcast message
result3 = GenStageAdapter.broadcast_vsm_message("status_check", %{"timestamp" => :os.system_time(:millisecond)}, %{})
IO.puts("Broadcast result: #{inspect(result3)}")

# Wait for message processing
:timer.sleep(500)

# Check final queue status
final_health = GenStageAdapter.health_check()
IO.puts("\nFinal Transport Health:")
IO.inspect(final_health, pretty: true)

IO.puts("\n=== Test Complete ===")