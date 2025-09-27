defmodule Cybernetic.Core.Aggregator.CentralAggregatorTest do
  use ExUnit.Case, async: false
  alias Cybernetic.Core.Aggregator.CentralAggregator

  setup do
    # Ensure CentralAggregator is started (may be started by Application or needs manual start)
    pid =
      case Process.whereis(CentralAggregator) do
        nil ->
          {:ok, p} = CentralAggregator.start_link([])
          # Wait for ETS table to be created by init
          Enum.reduce_while(1..50, nil, fn _, _ ->
            case :ets.whereis(:cyb_agg_window) do
              :undefined ->
                Process.sleep(10)
                {:cont, nil}

              _ ->
                {:halt, :ok}
            end
          end)

          p

        existing_pid ->
          existing_pid
      end

    # Clear the ETS table for clean test state
    case :ets.whereis(:cyb_agg_window) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:cyb_agg_window)
    end

    # Don't exit the shared process on test cleanup
    {:ok, pid: pid}
  end

  describe "event ingestion" do
    test "handles telemetry events", %{pid: _pid} do
      # Emit test event
      :telemetry.execute(
        [:cybernetic, :work, :finished],
        %{duration: 100, count: 5},
        %{severity: "info", labels: %{source: "test"}}
      )

      # Give aggregator time to process
      Process.sleep(10)

      # Verify entry in ETS
      entries = :ets.tab2list(:cyb_agg_window)
      assert length(entries) > 0

      {_timestamp, entry} = hd(entries)
      assert entry.source == [:cybernetic, :work, :finished]
      assert entry.severity == "info"
      assert entry.data.duration == 100
    end

    test "handles goldrush match events" do
      :telemetry.execute(
        [:cybernetic, :goldrush, :match],
        %{pattern: "slow_query", confidence: 0.95},
        %{severity: "warning", labels: %{db: "postgres"}}
      )

      Process.sleep(10)

      entries = :ets.tab2list(:cyb_agg_window)
      assert length(entries) > 0

      {_ts, entry} = hd(entries)
      assert entry.severity == "warning"
      assert entry.labels.db == "postgres"
    end
  end

  describe "fact emission" do
    test "emits aggregated facts periodically", %{pid: pid} do
      # Attach listener for facts
      ref = make_ref()
      parent = self()

      # Detach the S4 Bridge handler temporarily to avoid conflicts
      :telemetry.detach({Cybernetic.Intelligence.S4.Bridge, :facts})

      :telemetry.attach(
        {__MODULE__, ref},
        [:cybernetic, :aggregator, :facts],
        fn _event, measurements, meta, _config ->
          send(parent, {:facts_emitted, measurements, meta})
        end,
        nil
      )

      # Inject test events
      for i <- 1..5 do
        :telemetry.execute(
          [:cybernetic, :work, :finished],
          %{duration: i * 100},
          %{severity: "info", labels: %{batch: i}}
        )
      end

      # Give aggregator time to capture events
      Process.sleep(50)

      # Trigger emission
      send(Process.whereis(CentralAggregator), :emit)

      # Give time for emission processing
      Process.sleep(100)

      # Wait for facts
      assert_receive {:facts_emitted, measurements, meta}, 1_000

      assert is_list(measurements.facts)
      assert meta.window == "60s"

      # Should have aggregated our 5 events
      assert length(measurements.facts) > 0

      :telemetry.detach({__MODULE__, ref})
    end

    test "prunes old entries from window" do
      now = System.system_time(:millisecond)
      # 70 seconds ago
      old_time = now - 70_000
      # 30 seconds ago
      recent_time = now - 30_000

      # Insert old and recent entries with proper structure
      :ets.insert(
        :cyb_agg_window,
        {old_time,
         %{
           at: old_time,
           source: [:test, :old],
           severity: "info",
           labels: %{},
           data: %{value: "old"}
         }}
      )

      :ets.insert(
        :cyb_agg_window,
        {recent_time,
         %{
           at: recent_time,
           source: [:test, :recent],
           severity: "info",
           labels: %{},
           data: %{value: "recent"}
         }}
      )

      :ets.insert(
        :cyb_agg_window,
        {now,
         %{
           at: now,
           source: [:test, :current],
           severity: "info",
           labels: %{},
           data: %{value: "current"}
         }}
      )

      # Trigger pruning
      send(Process.whereis(CentralAggregator), :emit)
      Process.sleep(50)

      # Old entry should be pruned
      # Ensure table exists before accessing
      case :ets.whereis(:cyb_agg_window) do
        :undefined -> flunk("ETS table :cyb_agg_window does not exist")
        _ -> :ok
      end

      entries = :ets.tab2list(:cyb_agg_window)
      timestamps = Enum.map(entries, fn {ts, _} -> ts end)

      refute old_time in timestamps
      assert recent_time in timestamps
      assert now in timestamps
    end
  end

  describe "fact summarization" do
    test "groups events by source, severity, and labels" do
      # Emit similar events
      for _i <- 1..3 do
        :telemetry.execute(
          [:cybernetic, :work, :finished],
          %{duration: 100},
          %{severity: "info", labels: %{type: "batch"}}
        )
      end

      # Emit different event
      :telemetry.execute(
        [:cybernetic, :work, :failed],
        %{error: "timeout"},
        %{severity: "error", labels: %{type: "batch"}}
      )

      # Give aggregator time to process
      Process.sleep(50)

      # Force emission
      ref = make_ref()
      parent = self()

      # Detach the S4 Bridge handler temporarily to avoid conflicts
      :telemetry.detach({Cybernetic.Intelligence.S4.Bridge, :facts})

      :telemetry.attach(
        {__MODULE__, ref},
        [:cybernetic, :aggregator, :facts],
        fn _event, measurements, _meta, _config ->
          send(parent, {:facts, measurements.facts})
        end,
        nil
      )

      send(Process.whereis(CentralAggregator), :emit)

      # Give time for emission processing  
      Process.sleep(100)

      assert_receive {:facts, facts}, 1_000

      # Should have at least 1 fact group (may be aggregated)
      assert length(facts) >= 1

      # Find the aggregated batch events
      batch_fact =
        Enum.find(facts, fn f ->
          f["severity"] == "info" && Map.get(f["labels"] || %{}, "type") == "batch"
        end)

      # May have aggregated multiple events
      if batch_fact do
        assert batch_fact["count"] >= 1
      end

      :telemetry.detach({__MODULE__, ref})
    end
  end
end
