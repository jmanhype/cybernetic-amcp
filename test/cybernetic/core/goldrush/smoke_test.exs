defmodule Cybernetic.Core.Goldrush.SmokeTest do
  use ExUnit.Case
  
  setup do
    # Ensure Pipeline is started
    case GenServer.whereis(Cybernetic.Core.Goldrush.Pipeline) do
      nil -> 
        {:ok, _} = Cybernetic.Core.Goldrush.Pipeline.start_link([])
      _ -> 
        :ok
    end
    :ok
  end
  
  test "slow work emits algedonic :pain, fast emits :pleasure" do
    # Subscribe to algedonic events
    ref = make_ref()
    
    :telemetry.attach(
      {:catch_alg, ref},
      [:cybernetic, :algedonic],
      fn _e, meas, meta, _ -> send(self(), {:alg, meas, meta}) end,
      nil
    )
    
    # Emit slow work (should trigger pain)
    :telemetry.execute(
      [:cybernetic, :work, :finished],
      %{duration: 300},
      %{path: "/slow/endpoint", request_id: "req_001"}
    )
    
    assert_receive {:alg, %{severity: :pain}, meta}, 500
    assert meta.path == "/slow/endpoint"
    
    # Emit fast work (should trigger pleasure)
    :telemetry.execute(
      [:cybernetic, :work, :finished],
      %{duration: 20},
      %{path: "/fast/endpoint", request_id: "req_002"}
    )
    
    assert_receive {:alg, %{severity: :pleasure}, meta}, 500
    assert meta.path == "/fast/endpoint"
    
    # Emit medium work (should not trigger algedonic)
    :telemetry.execute(
      [:cybernetic, :work, :finished],
      %{duration: 100},
      %{path: "/normal/endpoint", request_id: "req_003"}
    )
    
    # Should not receive algedonic signal for medium latency
    refute_receive {:alg, _, _}, 200
    
    # Cleanup
    :telemetry.detach({:catch_alg, ref})
  end
  
  test "algedonic signals contain original context" do
    ref = make_ref()
    
    :telemetry.attach(
      {:catch_context, ref},
      [:cybernetic, :algedonic],
      fn _e, meas, meta, _ -> send(self(), {:alg_context, meas, meta}) end,
      nil
    )
    
    # Emit with rich context
    context = %{
      user_id: "user_123",
      session_id: "sess_456",
      action: "database_query",
      tags: ["slow", "critical"]
    }
    
    :telemetry.execute(
      [:cybernetic, :work, :finished],
      %{duration: 500, query_time: 450},
      context
    )
    
    assert_receive {:alg_context, %{severity: :pain}, meta}, 500
    
    # Original context should be preserved
    assert meta.user_id == "user_123"
    assert meta.session_id == "sess_456"
    assert meta.action == "database_query"
    assert meta.tags == ["slow", "critical"]
    
    # Cleanup
    :telemetry.detach({:catch_context, ref})
  end
  
  test "multiple plugins in pipeline" do
    # This test verifies the plugin pipeline can handle multiple plugins
    # For now we just have LatencyToAlgedonic, but the architecture supports more
    
    ref = make_ref()
    events = []
    
    :telemetry.attach(
      {:multi_test, ref},
      [:cybernetic, :algedonic],
      fn _e, meas, meta, _ -> 
        send(self(), {:multi, meas.severity})
      end,
      nil
    )
    
    # Send multiple events rapidly
    for i <- 1..5 do
      duration = if rem(i, 2) == 0, do: 300, else: 30
      
      :telemetry.execute(
        [:cybernetic, :work, :finished],
        %{duration: duration},
        %{index: i}
      )
    end
    
    # Collect results
    results = for _ <- 1..5 do
      receive do
        {:multi, severity} -> severity
      after
        100 -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
    
    # Should have mix of pain and pleasure
    assert :pain in results
    assert :pleasure in results
    
    # Cleanup
    :telemetry.detach({:multi_test, ref})
  end
end