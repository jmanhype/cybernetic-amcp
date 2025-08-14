defmodule Cybernetic.Intelligence.S4.BridgeTest do
  use ExUnit.Case, async: false
  alias Cybernetic.Intelligence.S4.Bridge

  # Mock provider for testing
  defmodule MockProvider do
    @behaviour Cybernetic.Intelligence.S4.Providers.LLMProvider

    @impl true
    def complete(_prompt, opts) do
      case opts[:response] do
        nil -> {:ok, ~s({"sop_updates": [{"action": "test", "priority": "high"}], "risk_score": 42})}
        :error -> {:error, :mock_error}
        response -> {:ok, response}
      end
    end
  end

  setup do
    # Clean up any existing telemetry handlers from Bridge
    :telemetry.list_handlers([:cybernetic, :aggregator, :facts])
    |> Enum.each(fn 
      %{id: {Bridge, _}} -> :telemetry.detach({Bridge, :facts})
      _ -> :ok 
    end)
    
    # Start a fresh Bridge for tests (or use existing if already started)
    pid = case Bridge.start_link(provider: MockProvider, provider_opts: []) do
      {:ok, p} -> p
      {:error, {:already_started, p}} -> p
    end
    on_exit(fn -> 
      Process.exit(pid, :normal)
      # Clean up handlers
      :telemetry.list_handlers([:cybernetic, :aggregator, :facts])
      |> Enum.each(fn 
        %{id: {Bridge, _}} -> :telemetry.detach({Bridge, :facts})
        _ -> :ok 
      end)
    end)
    
    {:ok, pid: pid}
  end

  describe "fact processing" do
    @tag :skip
    test "processes aggregator facts and queries LLM", %{pid: _pid} do
      # Attach listener for S4 analysis
      ref = make_ref()
      parent = self()
      
      :telemetry.attach(
        {__MODULE__, ref},
        [:cybernetic, :s4, :analysis],
        fn _event, measurements, meta, _config ->
          send(parent, {:s4_analysis, measurements, meta})
        end,
        nil
      )

      # Simulate aggregator emitting facts
      facts = [
        %{"source" => "test", "severity" => "error", "count" => 5},
        %{"source" => "db", "severity" => "warning", "count" => 2}
      ]
      
      :telemetry.execute(
        [:cybernetic, :aggregator, :facts],
        %{facts: facts},
        %{window: "60s"}
      )

      # Should receive S4 analysis
      assert_receive {:s4_analysis, measurements, meta}, 1_000
      
      assert measurements.ok == 1
      assert is_binary(meta.raw)
      
      # Verify it's valid JSON
      {:ok, parsed} = Jason.decode(meta.raw)
      assert parsed["risk_score"] == 42
      assert length(parsed["sop_updates"]) > 0
      
      :telemetry.detach({__MODULE__, ref})
    end

    @tag :skip  # Skipping due to test environment conflicts with telemetry handlers
    test "handles LLM provider errors gracefully", %{pid: pid} do
      # Stop the existing bridge
      Process.exit(pid, :normal)
      Process.sleep(10)
      
      # Clean up handlers
      :telemetry.list_handlers([:cybernetic, :aggregator, :facts])
      |> Enum.each(fn 
        %{id: {Bridge, _}} -> :telemetry.detach({Bridge, :facts})
        _ -> :ok 
      end)
      
      # Start a new Bridge with error response (or reuse if already started)
      case Bridge.start_link(provider: MockProvider, provider_opts: [response: :error]) do
        {:ok, _new_pid} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
      
      # Give Bridge time to attach its handlers
      Process.sleep(50)
      
      ref = make_ref()
      parent = self()
      
      :telemetry.attach(
        {__MODULE__, ref},
        [:cybernetic, :s4, :analysis],
        fn _event, measurements, meta, _config ->
          send(parent, {:s4_error, measurements, meta})
        end,
        nil
      )

      # Emit facts
      :telemetry.execute(
        [:cybernetic, :aggregator, :facts],
        %{facts: [%{"test" => "data"}]},
        %{window: "60s"}
      )

      # Should receive error telemetry
      assert_receive {:s4_error, measurements, meta}, 2_000
      
      assert measurements.error == 1
      assert meta.reason == :mock_error
      
      :telemetry.detach({__MODULE__, ref})
    end
  end

  describe "SOP forwarding" do
    test "forwards analysis to SOP Engine when available" do
      # Start SOP Engine or get existing
      sop_pid = case Process.whereis(Cybernetic.Intelligence.S4.SOPEngine) do
        nil -> 
          {:ok, pid} = Cybernetic.Intelligence.S4.SOPEngine.start_link([])
          pid
        existing -> existing
      end
      
      # Track messages to SOP Engine
      :erlang.trace(sop_pid, true, [:receive])
      
      # Emit facts to trigger S4
      :telemetry.execute(
        [:cybernetic, :aggregator, :facts],
        %{facts: [%{"test" => "sop_trigger"}]},
        %{window: "60s"}
      )

      # Wait for trace
      assert_receive {:trace, ^sop_pid, :receive, {:s4_output, output}}, 1_000
      
      assert is_binary(output)
      {:ok, parsed} = Jason.decode(output)
      assert Map.has_key?(parsed, "sop_updates")
      
      # Don't exit if it's the shared instance
      if Process.whereis(Cybernetic.Intelligence.S4.SOPEngine) != sop_pid do
        Process.exit(sop_pid, :normal)
      end
    end
  end

  describe "prompt generation" do
    test "creates structured prompts from observations" do
      observations = %{
        window: "5m",
        facts: [
          %{"source" => "api", "severity" => "error", "count" => 10},
          %{"source" => "db", "severity" => "warning", "count" => 3}
        ]
      }

      prompt = Cybernetic.Intelligence.S4.Prompts.Schemas.policy_gap_prompt(observations)
      
      # Verify prompt structure
      assert String.contains?(prompt, "System-4 policy analyst")
      assert String.contains?(prompt, "5m")
      assert String.contains?(prompt, "error")
      assert String.contains?(prompt, "SOP updates")
      assert String.contains?(prompt, "risk_score")
    end
  end
end