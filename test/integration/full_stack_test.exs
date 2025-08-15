defmodule Integration.FullStackTest do
  @moduledoc """
  Real-world integration test verifying all components work together.
  Tests the complete flow from user request through VSM layers to response.
  """
  use ExUnit.Case
  require Logger
  
  @test_timeout 30_000
  
  setup_all do
    # Ensure all applications are started
    Application.ensure_all_started(:amqp)
    Application.ensure_all_started(:redix)
    Application.ensure_all_started(:httpoison)
    Application.ensure_all_started(:opentelemetry)
    Application.ensure_all_started(:cybernetic)
    
    # Wait for services to stabilize
    Process.sleep(3000)
    
    # Verify services are available
    assert service_health_check()
    
    :ok
  end
  
  describe "Full Stack Integration" do
    @tag timeout: @test_timeout
    test "complete VSM message flow with all services" do
      Logger.info("Starting full stack integration test")
      
      # 1. Generate telemetry trace
      trace_ctx = :otel_tracer.start_span("integration_test")
      
      # 2. Submit request through S5 (Policy)
      request = %{
        type: "analyze",
        content: "What is the system status?",
        metadata: %{
          trace_id: elem(trace_ctx, 0),
          timestamp: System.system_time(:millisecond)
        }
      }
      
      # 3. Send through RabbitMQ VSM hierarchy
      {:ok, conn} = AMQP.Connection.open()
      {:ok, channel} = AMQP.Channel.open(conn)
      
      # Declare response queue
      {:ok, %{queue: response_queue}} = AMQP.Queue.declare(channel, "", exclusive: true)
      
      # Subscribe to response
      AMQP.Basic.consume(channel, response_queue)
      
      # Publish to S5 Policy queue
      AMQP.Basic.publish(
        channel,
        "vsm.topic",
        "vsm.system5.policy",
        Jason.encode!(request),
        reply_to: response_queue,
        correlation_id: UUID.uuid4()
      )
      
      # 4. Wait for response through VSM cascade
      response = receive do
        {:basic_deliver, payload, meta} ->
          Logger.info("Received response: #{inspect(payload)}")
          Jason.decode!(payload)
      after
        10_000 -> 
          flunk("Timeout waiting for VSM response")
      end
      
      # 5. Verify response structure
      assert response["status"] in ["success", "processed"]
      assert response["episode_id"]
      assert response["systems_involved"]
      
      # 6. Check Redis for state persistence
      {:ok, redis} = Redix.start_link()
      {:ok, state_data} = Redix.command(redis, ["GET", "vsm:state:#{response["episode_id"]}"])
      
      if state_data do
        state = Jason.decode!(state_data)
        assert state["processed_by"]
        Logger.info("State persisted: #{inspect(state)}")
      end
      
      # 7. Verify S4 Memory stored the episode
      alias Cybernetic.VSM.System4.Memory
      {:ok, context} = Memory.get_context(response["episode_id"])
      assert length(context) > 0
      
      # 8. Check Prometheus metrics updated
      metrics = fetch_prometheus_metrics()
      assert metrics =~ "vsm_messages_processed_total"
      
      # 9. Verify OpenTelemetry span
      :otel_tracer.end_span(trace_ctx)
      
      # Cleanup
      AMQP.Channel.close(channel)
      AMQP.Connection.close(conn)
      GenServer.stop(redis)
      
      Logger.info("Full stack integration test completed successfully")
    end
    
    @tag timeout: @test_timeout
    test "multi-provider S4 routing with fallback" do
      Logger.info("Testing multi-provider S4 routing")
      
      alias Cybernetic.VSM.System4.Service
      
      # Test different task types route to appropriate providers
      tasks = [
        %{type: :reasoning, content: "Complex logical problem"},
        %{type: :code_generation, content: "Write a function"},
        %{type: :general, content: "Basic question"}
      ]
      
      for task <- tasks do
        episode_id = "test-routing-#{System.unique_integer()}"
        
        result = Service.route_episode(%{
          id: episode_id,
          task: task,
          budget: %{max_tokens: 1000}
        })
        
        assert {:ok, response} = result
        assert response.provider
        assert response.content
        
        Logger.info("Task #{task.type} routed to #{response.provider}")
      end
    end
    
    @tag timeout: @test_timeout
    test "CRDT state synchronization across nodes" do
      Logger.info("Testing CRDT state synchronization")
      
      alias Cybernetic.Core.CRDT.Merge
      
      # Create two CRDT instances (simulating different nodes)
      crdt1 = %Merge{id: "node1", state: %{}, vector_clock: %{}}
      crdt2 = %Merge{id: "node2", state: %{}, vector_clock: %{}}
      
      # Update on node1
      crdt1 = Merge.update(crdt1, "key1", "value1")
      
      # Update on node2
      crdt2 = Merge.update(crdt2, "key2", "value2")
      
      # Merge states
      merged = Merge.merge(crdt1, crdt2)
      
      assert merged.state["key1"] == "value1"
      assert merged.state["key2"] == "value2"
      assert map_size(merged.vector_clock) == 2
      
      Logger.info("CRDT merge successful: #{inspect(merged.state)}")
    end
    
    @tag timeout: @test_timeout
    test "circuit breaker and rate limiting" do
      Logger.info("Testing circuit breaker and rate limiting")
      
      alias Cybernetic.Core.Security.RateLimiter
      alias Cybernetic.Transport.CircuitBreaker
      
      # Test rate limiter
      client_id = "test-client-#{System.unique_integer()}"
      
      # Should allow initial requests
      assert :ok = RateLimiter.check_rate(client_id, :api_call)
      assert :ok = RateLimiter.check_rate(client_id, :api_call)
      
      # Flood with requests to trigger limit
      results = for _ <- 1..20 do
        RateLimiter.check_rate(client_id, :api_call)
      end
      
      assert Enum.any?(results, &(&1 == {:error, :rate_limited}))
      
      # Test circuit breaker
      breaker = CircuitBreaker.new("test-service")
      
      # Simulate failures
      breaker = Enum.reduce(1..10, breaker, fn _, acc ->
        CircuitBreaker.record_failure(acc)
      end)
      
      assert breaker.state == :open
      Logger.info("Circuit breaker opened after failures")
    end
    
    @tag timeout: @test_timeout
    test "end-to-end observability pipeline" do
      Logger.info("Testing observability pipeline")
      
      # Start a traced operation
      :otel_tracer.with_span "e2e_test" do
        # Add span attributes
        :otel_span.set_attributes([
          {"test.type", "integration"},
          {"test.component", "vsm"}
        ])
        
        # Simulate work with nested spans
        :otel_tracer.with_span "database_query" do
          Process.sleep(100)
          :otel_span.set_attribute("db.statement", "SELECT * FROM events")
        end
        
        :otel_tracer.with_span "amqp_publish" do
          Process.sleep(50)
          :otel_span.set_attribute("messaging.system", "rabbitmq")
        end
      end
      
      # Verify metrics are collected
      {:ok, response} = HTTPoison.get("http://localhost:9090/api/v1/query?query=up")
      assert response.status_code == 200
      
      data = Jason.decode!(response.body)
      assert data["status"] == "success"
      
      Logger.info("Observability pipeline verified")
    end
  end
  
  # Helper Functions
  
  defp service_health_check do
    services = [
      {"RabbitMQ", &check_rabbitmq/0},
      {"Redis", &check_redis/0},
      {"Prometheus", &check_prometheus/0}
    ]
    
    results = Enum.map(services, fn {name, check_fn} ->
      case check_fn.() do
        :ok ->
          Logger.info("✓ #{name} is healthy")
          true
        _ ->
          Logger.error("✗ #{name} is not available")
          false
      end
    end)
    
    Enum.all?(results)
  end
  
  defp check_rabbitmq do
    case AMQP.Connection.open() do
      {:ok, conn} ->
        AMQP.Connection.close(conn)
        :ok
      _ -> :error
    end
  end
  
  defp check_redis do
    case Redix.start_link(host: "localhost", port: 6379, password: "changeme") do
      {:ok, conn} ->
        GenServer.stop(conn)
        :ok
      _ -> :error
    end
  end
  
  defp check_prometheus do
    case HTTPoison.get("http://localhost:9090/-/healthy") do
      {:ok, %{status_code: 200}} -> :ok
      _ -> :error
    end
  end
  
  defp fetch_prometheus_metrics do
    case HTTPoison.get("http://localhost:9090/api/v1/query?query=up") do
      {:ok, response} -> response.body
      _ -> ""
    end
  end
end