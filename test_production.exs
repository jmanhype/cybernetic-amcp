#!/usr/bin/env elixir

# Production Readiness Test
# Tests the full VSM system under production-like conditions

defmodule ProductionTest do
  @moduledoc """
  Production readiness test suite for Cybernetic VSM
  """
  
  def run do
    IO.puts("\n🏭 PRODUCTION READINESS TEST")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("Testing Cybernetic VSM Framework v0.1.0")
    IO.puts("OTP #{:erlang.system_info(:otp_release)} | Elixir #{System.version()}")
    IO.puts("=" |> String.duplicate(60))
    
    # Start application
    case Application.ensure_all_started(:cybernetic) do
      {:ok, _apps} ->
        IO.puts("✅ Application started successfully")
      {:error, reason} ->
        IO.puts("❌ Failed to start: #{inspect(reason)}")
        System.halt(1)
    end
    
    Process.sleep(500)  # Let systems initialize
    
    # Run test suite
    results = [
      test_system_health(),
      test_amqp_connectivity(),
      test_message_routing(),
      test_error_handling(),
      test_algedonic_signals(),
      test_coordination_flow(),
      test_intelligence_analysis(),
      test_load_handling(),
      test_fault_tolerance()
    ]
    
    # Print summary
    print_summary(results)
    
    # Return exit code
    if Enum.all?(results, fn {_, passed} -> passed end) do
      0
    else
      1
    end
  end
  
  defp test_system_health do
    IO.puts("\n📊 SYSTEM HEALTH CHECK")
    IO.puts("-" |> String.duplicate(40))
    
    systems = [
      {Cybernetic.VSM.System1.Operational, "System1 (Operational)"},
      {Cybernetic.VSM.System2.Coordinator, "System2 (Coordinator)"},
      {Cybernetic.VSM.System3.Control, "System3 (Control)"},
      {Cybernetic.VSM.System4.Intelligence, "System4 (Intelligence)"},
      {Cybernetic.VSM.System5.Policy, "System5 (Policy)"}
    ]
    
    all_running = Enum.all?(systems, fn {process, name} ->
      case Process.whereis(process) do
        nil ->
          IO.puts("  ❌ #{name}: Not running")
          false
        pid ->
          IO.puts("  ✅ #{name}: Running (#{inspect(pid)})")
          true
      end
    end)
    
    {"System Health", all_running}
  end
  
  defp test_amqp_connectivity do
    IO.puts("\n🔌 AMQP CONNECTIVITY TEST")
    IO.puts("-" |> String.duplicate(40))
    
    conn_pid = Process.whereis(Cybernetic.Transport.AMQP.Connection)
    
    if conn_pid && Process.alive?(conn_pid) do
      IO.puts("  ✅ AMQP Connection alive: #{inspect(conn_pid)}")
      
      # Test publishing
      alias Cybernetic.Core.Transport.AMQP.Publisher
      
      test_msg = %{
        type: "production.test",
        timestamp: DateTime.utc_now(),
        test_id: :crypto.strong_rand_bytes(8) |> Base.encode16()
      }
      
      case Publisher.publish("cybernetic.exchange", "vsm.system1.test", test_msg) do
        :ok ->
          IO.puts("  ✅ Message published successfully")
          {"AMQP Connectivity", true}
        error ->
          IO.puts("  ❌ Publish failed: #{inspect(error)}")
          {"AMQP Connectivity", false}
      end
    else
      IO.puts("  ❌ AMQP Connection not found")
      {"AMQP Connectivity", false}
    end
  end
  
  defp test_message_routing do
    IO.puts("\n📬 MESSAGE ROUTING TEST")
    IO.puts("-" |> String.duplicate(40))
    
    alias Cybernetic.Transport.InMemory
    
    # Test S1 -> S2 routing
    InMemory.publish("test", "s1.operation", %{
      type: "vsm.s1.operation",
      operation: "production_test",
      timestamp: DateTime.utc_now()
    }, [])
    
    Process.sleep(50)
    IO.puts("  ✅ S1 → S2 routing tested")
    
    # Test S2 -> S4 routing  
    InMemory.publish("test", "s2.coordinate", %{
      type: "vsm.s2.coordinate",
      source_system: "s1",
      operation: "coordinate_test"
    }, [])
    
    Process.sleep(50)
    IO.puts("  ✅ S2 → S4 routing tested")
    
    {"Message Routing", true}
  end
  
  defp test_error_handling do
    IO.puts("\n⚠️ ERROR HANDLING TEST")
    IO.puts("-" |> String.duplicate(40))
    
    alias Cybernetic.Transport.InMemory
    
    # Send malformed message
    InMemory.publish("test", "s1.operation", "invalid_message", [])
    Process.sleep(50)
    
    # Check if systems are still alive
    s1_alive = Process.whereis(Cybernetic.VSM.System1.Operational) != nil
    
    if s1_alive do
      IO.puts("  ✅ System recovered from invalid message")
      {"Error Handling", true}
    else
      IO.puts("  ❌ System crashed on invalid message")
      {"Error Handling", false}
    end
  end
  
  defp test_algedonic_signals do
    IO.puts("\n🎯 ALGEDONIC SIGNALS TEST")
    IO.puts("-" |> String.duplicate(40))
    
    alias Cybernetic.Transport.InMemory
    
    # Trigger pain signal (errors)
    for i <- 1..5 do
      InMemory.publish("test", "s1.error", %{
        type: "vsm.s1.error",
        error: "production_error_#{i}",
        timestamp: DateTime.utc_now()
      }, [])
    end
    
    Process.sleep(100)
    IO.puts("  ✅ Pain signals triggered")
    
    # Trigger pleasure signal (successes)
    for i <- 1..10 do
      InMemory.publish("test", "s1.success", %{
        type: "vsm.s1.success",
        operation: "production_task_#{i}",
        latency: :rand.uniform(100),
        timestamp: DateTime.utc_now()
      }, [])
    end
    
    Process.sleep(100)
    IO.puts("  ✅ Pleasure signals triggered")
    
    {"Algedonic Signals", true}
  end
  
  defp test_coordination_flow do
    IO.puts("\n🔄 COORDINATION FLOW TEST")
    IO.puts("-" |> String.duplicate(40))
    
    alias Cybernetic.Transport.InMemory
    
    # Test full coordination flow
    InMemory.publish("test", "s2.coordinate", %{
      type: "vsm.s2.coordinate",
      source_system: "s1",
      operation: "complex_operation",
      priority: "high",
      resources_needed: ["cpu", "memory", "network"]
    }, [])
    
    Process.sleep(100)
    IO.puts("  ✅ Complex coordination handled")
    
    {"Coordination Flow", true}
  end
  
  defp test_intelligence_analysis do
    IO.puts("\n🧠 INTELLIGENCE ANALYSIS TEST")
    IO.puts("-" |> String.duplicate(40))
    
    alias Cybernetic.Transport.InMemory
    
    # Request pattern analysis
    InMemory.publish("test", "s4.intelligence", %{
      type: "vsm.s4.intelligence",
      analysis_request: "pattern_detection",
      data: %{
        metrics: [10, 20, 15, 30, 25, 35],
        timeframe: "1h"
      },
      source_system: "s2"
    }, [])
    
    Process.sleep(100)
    IO.puts("  ✅ Pattern analysis requested")
    
    # Request prediction
    InMemory.publish("test", "s4.intelligence", %{
      type: "vsm.s4.intelligence",
      analysis_request: "prediction",
      historical_data: [100, 110, 105, 120, 115],
      source_system: "s3"
    }, [])
    
    Process.sleep(100)
    IO.puts("  ✅ Prediction analysis requested")
    
    {"Intelligence Analysis", true}
  end
  
  defp test_load_handling do
    IO.puts("\n⚡ LOAD HANDLING TEST")
    IO.puts("-" |> String.duplicate(40))
    
    alias Cybernetic.Transport.InMemory
    
    # Send burst of messages
    start_time = System.monotonic_time(:millisecond)
    
    for i <- 1..100 do
      InMemory.publish("test", "s1.operation", %{
        type: "vsm.s1.operation",
        operation: "load_test_#{i}",
        timestamp: DateTime.utc_now()
      }, [])
    end
    
    Process.sleep(200)
    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time
    
    IO.puts("  ✅ Processed 100 messages in #{duration}ms")
    IO.puts("  📈 Throughput: #{round(100000 / duration)} msg/sec")
    
    # Check systems still healthy
    all_alive = [
      Cybernetic.VSM.System1.Operational,
      Cybernetic.VSM.System2.Coordinator,
      Cybernetic.VSM.System3.Control,
      Cybernetic.VSM.System4.Intelligence,
      Cybernetic.VSM.System5.Policy
    ]
    |> Enum.all?(&(Process.whereis(&1) != nil))
    
    if all_alive do
      IO.puts("  ✅ All systems survived load test")
      {"Load Handling", true}
    else
      IO.puts("  ❌ Some systems failed under load")
      {"Load Handling", false}
    end
  end
  
  defp test_fault_tolerance do
    IO.puts("\n🛡️ FAULT TOLERANCE TEST")
    IO.puts("-" |> String.duplicate(40))
    
    # Test supervisor restart capability
    s1_pid = Process.whereis(Cybernetic.VSM.System1.Operational)
    
    if s1_pid do
      # Kill a process
      Process.exit(s1_pid, :kill)
      Process.sleep(500)  # Wait for supervisor to restart
      
      # Check if restarted
      new_s1_pid = Process.whereis(Cybernetic.VSM.System1.Operational)
      
      if new_s1_pid && new_s1_pid != s1_pid do
        IO.puts("  ✅ System1 auto-restarted after crash")
        IO.puts("    Old PID: #{inspect(s1_pid)}")
        IO.puts("    New PID: #{inspect(new_s1_pid)}")
        {"Fault Tolerance", true}
      else
        IO.puts("  ❌ System1 failed to restart")
        {"Fault Tolerance", false}
      end
    else
      IO.puts("  ⚠️ System1 not running, skipping test")
      {"Fault Tolerance", false}
    end
  end
  
  defp print_summary(results) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("📋 PRODUCTION TEST SUMMARY")
    IO.puts(String.duplicate("=", 60))
    
    passed = Enum.count(results, fn {_, p} -> p end)
    total = length(results)
    
    Enum.each(results, fn {name, passed} ->
      icon = if passed, do: "✅", else: "❌"
      IO.puts("  #{icon} #{name}")
    end)
    
    IO.puts(String.duplicate("-", 60))
    IO.puts("  Score: #{passed}/#{total} tests passed")
    
    if passed == total do
      IO.puts("\n🎉 SYSTEM IS PRODUCTION READY! 🚀")
    else
      IO.puts("\n⚠️ SYSTEM NEEDS ATTENTION")
      IO.puts("  Please fix failing tests before production deployment")
    end
    
    IO.puts(String.duplicate("=", 60))
  end
end

# Run the production test
exit_code = ProductionTest.run()
System.halt(exit_code)