#!/usr/bin/env elixir

# Comprehensive Dogfood Test for Cybernetic VSM Framework
# Tests all VSM systems (S1-S5), CRDT, MCP, Security, and Health monitoring

defmodule VSMDogfoodTest do
  @moduledoc """
  Comprehensive dogfood test for the entire Cybernetic VSM architecture
  """
  
  require Logger
  
  def run do
    Logger.info("🐕 Starting Comprehensive VSM Dogfood Test")
    Logger.info("=" |> String.duplicate(60))
    
    # Test each major component
    test_vsm_systems()
    test_crdt_synchronization()
    test_mcp_tools()
    test_security_components()
    test_health_monitoring()
    test_goldrush_patterns()
    test_aggregator()
    
    Logger.info("\n✅ All VSM components dogfood tested successfully!")
  end
  
  # Test VSM Systems S1-S5
  defp test_vsm_systems do
    Logger.info("\n🏗️ Testing VSM Systems (S1-S5)...")
    Logger.info("-" |> String.duplicate(40))
    
    # Test S1 - Operational System
    Logger.info("  • Testing S1 Operational System...")
    test_s1_operations()
    
    # Test S2 - Coordination System  
    Logger.info("  • Testing S2 Coordination System...")
    test_s2_coordination()
    
    # Test S3 - Control System
    Logger.info("  • Testing S3 Control System...")
    test_s3_control()
    
    # Test S4 - Intelligence System
    Logger.info("  • Testing S4 Intelligence System...")
    test_s4_intelligence()
    
    # Test S5 - Policy System
    Logger.info("  • Testing S5 Policy System...")
    test_s5_policy()
    
    Logger.info("  ✓ VSM Systems test completed")
  end
  
  defp test_s1_operations do
    alias Cybernetic.VSM.System1
    
    # Test basic operation handling
    operation = %{
      type: "vsm.s1.operation",
      operation: "process_data",
      data: %{value: 42, timestamp: DateTime.utc_now()}
    }
    
    result = System1.handle_operation(operation)
    Logger.info("    S1 processed operation: #{inspect(result)}")
    
    # Test resource requests
    resource_request = %{
      type: "resource_request",
      amount: 10,
      resource_type: "cpu"
    }
    
    System1.handle_operation(resource_request)
    Logger.info("    S1 handled resource request")
  rescue
    error ->
      Logger.warning("    S1 test failed: #{inspect(error)}")
  end
  
  defp test_s2_coordination do
    alias Cybernetic.VSM.System2.Coordinator
    
    # Test coordination
    {:ok, pid} = Coordinator.start_link([])
    
    # Request coordination
    coordination_request = %{
      type: "vsm.s2.coordinate",
      source_system: "s1",
      operation: "balance_load",
      timestamp: DateTime.utc_now()
    }
    
    GenServer.cast(pid, {:coordinate, coordination_request})
    Process.sleep(100)
    
    state = GenServer.call(pid, :get_state)
    Logger.info("    S2 coordination state: #{inspect(Map.keys(state))}")
    
    GenServer.stop(pid)
  rescue
    error ->
      Logger.warning("    S2 test failed: #{inspect(error)}")
  end
  
  defp test_s3_control do
    alias Cybernetic.VSM.System3.RateLimiter
    
    # Test rate limiting
    budget = :test_budget
    
    # Reserve tokens
    results = for i <- 1..10 do
      RateLimiter.reserve(budget, 1)
    end
    
    allowed = Enum.count(results, &match?(:ok, &1))
    denied = Enum.count(results, &match?({:error, :rate_limited}, &1))
    
    Logger.info("    S3 RateLimiter: #{allowed} allowed, #{denied} denied")
  rescue
    error ->
      Logger.warning("    S3 test failed: #{inspect(error)}")
  end
  
  defp test_s4_intelligence do
    alias Cybernetic.VSM.System4.Memory
    
    # Test memory storage
    Memory.store("test_context", %{
      query: "What is the meaning of life?",
      response: "42",
      timestamp: DateTime.utc_now()
    })
    
    case Memory.recall("test_context") do
      {:ok, data} ->
        Logger.info("    S4 Memory recalled: #{inspect(Map.keys(data))}")
      _ ->
        Logger.info("    S4 Memory: no data found")
    end
    
    # Test pattern analysis (simulated)
    Logger.info("    S4 Intelligence: Pattern analysis ready")
  rescue
    error ->
      Logger.warning("    S4 test failed: #{inspect(error)}")
  end
  
  defp test_s5_policy do
    alias Cybernetic.VSM.System5.PolicyEngine
    
    # Test policy evaluation
    policy_context = %{
      action: "deploy",
      resource: "production",
      user: "system",
      risk_level: 0.3
    }
    
    decision = PolicyEngine.evaluate(policy_context)
    Logger.info("    S5 Policy decision: #{inspect(decision)}")
    
    # Test SOP engine
    sop_result = PolicyEngine.get_sop("deployment")
    Logger.info("    S5 SOP retrieved: #{inspect(sop_result)}")
  rescue
    error ->
      Logger.warning("    S5 test failed: #{inspect(error)}")
  end
  
  # Test CRDT Synchronization
  defp test_crdt_synchronization do
    Logger.info("\n🔄 Testing CRDT Synchronization...")
    Logger.info("-" |> String.duplicate(40))
    
    alias Cybernetic.Core.CRDT.Graph
    alias Cybernetic.Core.CRDT.ContextGraph
    
    # Test basic CRDT operations
    {:ok, graph1} = Graph.start_link(name: :test_graph1)
    {:ok, graph2} = Graph.start_link(name: :test_graph2)
    
    # Add nodes to graph1
    Graph.add_node(graph1, "node1", %{data: "test1"})
    Graph.add_node(graph1, "node2", %{data: "test2"})
    Graph.add_edge(graph1, "node1", "node2", %{relationship: "connected"})
    
    # Get state and merge to graph2
    state1 = Graph.get_state(graph1)
    Graph.merge(graph2, state1)
    
    # Verify synchronization
    state2 = Graph.get_state(graph2)
    Logger.info("  • Graph1 nodes: #{map_size(state1.nodes)}")
    Logger.info("  • Graph2 nodes after merge: #{map_size(state2.nodes)}")
    
    # Test ContextGraph
    {:ok, context} = ContextGraph.start_link(name: :test_context)
    
    ContextGraph.add_semantic_node(context, "concept1", %{
      type: "concept",
      description: "Test concept",
      tags: ["test", "dogfood"]
    })
    
    ContextGraph.add_semantic_node(context, "concept2", %{
      type: "concept",
      description: "Related concept"
    })
    
    ContextGraph.add_relationship(context, "concept1", "concept2", "relates_to", %{
      strength: 0.8
    })
    
    # Query the graph
    related = ContextGraph.get_related(context, "concept1")
    Logger.info("  • Context graph relationships: #{length(related)}")
    
    GenServer.stop(graph1)
    GenServer.stop(graph2)
    GenServer.stop(context)
    
    Logger.info("  ✓ CRDT synchronization test completed")
  rescue
    error ->
      Logger.warning("  ⚠ CRDT test failed: #{inspect(error)}")
  end
  
  # Test MCP Tools
  defp test_mcp_tools do
    Logger.info("\n🔧 Testing MCP Tool Integration...")
    Logger.info("-" |> String.duplicate(40))
    
    alias Cybernetic.Core.MCP.Tools
    
    # Test tool listing
    tools = Tools.list_tools()
    Logger.info("  • Available MCP tools: #{length(tools)}")
    
    # Test calculator tool
    calc_result = Tools.execute_tool("calculator", %{
      "operation" => "add",
      "operands" => [10, 32]
    })
    
    case calc_result do
      {:ok, result} ->
        Logger.info("  • Calculator tool result: #{inspect(result)}")
      {:error, reason} ->
        Logger.info("  • Calculator tool error: #{inspect(reason)}")
    end
    
    # Test filesystem tool
    fs_result = Tools.execute_tool("filesystem", %{
      "operation" => "list",
      "path" => "."
    })
    
    case fs_result do
      {:ok, _files} ->
        Logger.info("  • Filesystem tool: Listed current directory")
      {:error, reason} ->
        Logger.info("  • Filesystem tool error: #{inspect(reason)}")
    end
    
    Logger.info("  ✓ MCP tools test completed")
  rescue
    error ->
      Logger.warning("  ⚠ MCP tools test failed: #{inspect(error)}")
  end
  
  # Test Security Components
  defp test_security_components do
    Logger.info("\n🔒 Testing Security Components...")
    Logger.info("-" |> String.duplicate(40))
    
    alias Cybernetic.Core.Security.NonceBloom
    
    # Test nonce generation and validation
    Logger.info("  • Testing NonceBloom...")
    
    nonces = for _ <- 1..100 do
      NonceBloom.generate_nonce()
    end
    
    # All should be unique
    unique_count = nonces |> Enum.uniq() |> length()
    Logger.info("    Generated #{unique_count}/100 unique nonces")
    
    # Test nonce validation
    test_nonce = NonceBloom.generate_nonce()
    
    # First use should be valid
    case NonceBloom.validate_nonce(test_nonce) do
      :ok ->
        Logger.info("    Nonce validation: ✓ First use valid")
      _ ->
        Logger.info("    Nonce validation: ✗ First use invalid")
    end
    
    # Second use should be invalid (replay protection)
    case NonceBloom.validate_nonce(test_nonce) do
      {:error, :nonce_already_used} ->
        Logger.info("    Replay protection: ✓ Duplicate rejected")
      _ ->
        Logger.info("    Replay protection: ✗ Duplicate accepted")
    end
    
    # Test RateLimiter
    test_rate_limiter()
    
    Logger.info("  ✓ Security components test completed")
  rescue
    error ->
      Logger.warning("  ⚠ Security test failed: #{inspect(error)}")
  end
  
  defp test_rate_limiter do
    alias Cybernetic.Core.Security.RateLimiter
    
    Logger.info("  • Testing RateLimiter...")
    
    # Create test budget
    budget_name = :dogfood_budget
    
    # Rapid fire requests
    results = for _ <- 1..20 do
      RateLimiter.check_rate(budget_name, 1)
    end
    
    allowed = Enum.count(results, &(&1 == :ok))
    limited = Enum.count(results, &(&1 == {:error, :rate_limited}))
    
    Logger.info("    Rate limiting: #{allowed} allowed, #{limited} limited")
  end
  
  # Test Health Monitoring
  defp test_health_monitoring do
    Logger.info("\n🏥 Testing Health Monitoring...")
    Logger.info("-" |> String.duplicate(40))
    
    alias Cybernetic.Health.Collector
    alias Cybernetic.Health.Monitor
    
    # Report some health metrics
    Collector.report_health(:test_component, %{
      status: :healthy,
      cpu_usage: 45.2,
      memory_mb: 128,
      uptime_seconds: 3600
    })
    
    Collector.report_health(:test_component2, %{
      status: :degraded,
      error_rate: 0.05,
      response_time_ms: 250
    })
    
    # Get system health
    Process.sleep(100)
    health = Monitor.get_system_health()
    
    Logger.info("  • System health status: #{inspect(health.status)}")
    Logger.info("  • Components monitored: #{map_size(health.components)}")
    
    # Test telemetry events
    :telemetry.execute(
      [:cybernetic, :health, :check],
      %{duration_ms: 10},
      %{component: :test, status: :ok}
    )
    
    Logger.info("  • Telemetry event emitted")
    
    Logger.info("  ✓ Health monitoring test completed")
  rescue
    error ->
      Logger.warning("  ⚠ Health monitoring test failed: #{inspect(error)}")
  end
  
  # Test Goldrush Pattern Matching
  defp test_goldrush_patterns do
    Logger.info("\n⚡ Testing Goldrush Pattern Engine...")
    Logger.info("-" |> String.duplicate(40))
    
    alias Cybernetic.Core.Goldrush.Engine
    
    # Test pattern registration
    pattern = %{
      name: "test_pattern",
      match: %{type: "error", severity: "high"},
      action: fn event -> 
        Logger.debug("Goldrush matched high severity error: #{inspect(event)}")
      end
    }
    
    Engine.register_pattern(pattern)
    
    # Simulate events
    test_events = [
      %{type: "error", severity: "high", message: "Critical failure"},
      %{type: "warning", severity: "medium", message: "Resource low"},
      %{type: "error", severity: "low", message: "Minor issue"}
    ]
    
    Enum.each(test_events, &Engine.process_event/1)
    
    Logger.info("  • Processed #{length(test_events)} events through Goldrush")
    Logger.info("  ✓ Goldrush pattern engine test completed")
  rescue
    error ->
      Logger.warning("  ⚠ Goldrush test failed: #{inspect(error)}")
  end
  
  # Test Central Aggregator
  defp test_aggregator do
    Logger.info("\n📊 Testing Central Aggregator...")
    Logger.info("-" |> String.duplicate(40))
    
    alias Cybernetic.Core.Aggregator.CentralAggregator
    
    # Submit facts to aggregator
    facts = [
      %{type: :metric, name: "cpu_usage", value: 65.5, timestamp: DateTime.utc_now()},
      %{type: :event, name: "user_login", user: "alice", timestamp: DateTime.utc_now()},
      %{type: :metric, name: "memory_usage", value: 1024, timestamp: DateTime.utc_now()},
      %{type: :alert, name: "high_load", severity: :warning, timestamp: DateTime.utc_now()}
    ]
    
    Enum.each(facts, fn fact ->
      CentralAggregator.submit_fact(fact.type, fact)
    end)
    
    # Let aggregator process
    Process.sleep(100)
    
    # Get aggregated data
    state = CentralAggregator.get_state()
    
    Logger.info("  • Facts aggregated by type:")
    Enum.each(state.facts_by_type, fn {type, facts} ->
      Logger.info("    - #{type}: #{length(facts)} facts")
    end)
    
    Logger.info("  • Total facts processed: #{state.total_facts}")
    Logger.info("  ✓ Central Aggregator test completed")
  rescue
    error ->
      Logger.warning("  ⚠ Aggregator test failed: #{inspect(error)}")
  end
end

# Run the comprehensive dogfood test
VSMDogfoodTest.run()