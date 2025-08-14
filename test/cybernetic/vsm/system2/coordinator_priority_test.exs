defmodule Cybernetic.VSM.System2.CoordinatorPriorityTest do
  use ExUnit.Case, async: false
  alias Cybernetic.VSM.System2.Coordinator
  
  setup do
    # Ensure telemetry is started for tests
    Application.ensure_all_started(:telemetry)
    :ok
  end

  describe "weighted fair share" do
    test "2:1 split allocation" do
      # Stop existing coordinator and start fresh with test config
      case Process.whereis(Coordinator) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 100)
      end
      Process.sleep(10)
      
      {:ok, _pid} = Coordinator.start_link(max_slots: 12)
      
      Coordinator.set_priority(:hi, 2.0)
      Coordinator.set_priority(:lo, 1.0)
      Process.sleep(10)
      
      # Reserve slots for high priority
      hi_slots = for _ <- 1..12 do
        case Coordinator.reserve_slot(:hi) do
          :ok -> 1
          :backpressure -> 0
        end
      end |> Enum.sum()
      
      # Release all hi slots
      for _ <- 1..hi_slots, do: Coordinator.release_slot(:hi)
      Process.sleep(10)
      
      # Reserve slots for low priority  
      lo_slots = for _ <- 1..12 do
        case Coordinator.reserve_slot(:lo) do
          :ok -> 1
          :backpressure -> 0
        end
      end |> Enum.sum()
      
      # With 2:1 ratio, hi should get ~8 slots, lo should get ~4
      assert hi_slots in 7..9
      assert lo_slots in 3..5
    end
  end

  describe "aging prevents starvation" do
    test "low priority gets slots after aging" do
      case Process.whereis(Coordinator) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 100)
      end
      Process.sleep(10)
      
      {:ok, _pid} = Coordinator.start_link(
        max_slots: 4, 
        aging_ms: 50, 
        aging_boost: 1.0
      )
      
      Coordinator.set_priority(:hi, 100.0)
      Coordinator.set_priority(:lo, 1.0)
      Process.sleep(10)
      
      # Fill all slots with high priority
      for _ <- 1..4, do: Coordinator.reserve_slot(:hi)
      
      # Initially low priority should be blocked
      assert Coordinator.reserve_slot(:lo) == :backpressure
      
      # Wait for aging to kick in
      Process.sleep(60)
      
      # Release one high priority slot
      Coordinator.release_slot(:hi)
      Process.sleep(10)
      
      # Now low priority should get a slot due to aging
      assert Coordinator.reserve_slot(:lo) == :ok
    end
  end
  
  describe "telemetry events" do
    test "emits schedule event on successful reservation" do
      case Process.whereis(Coordinator) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 100)
      end
      Process.sleep(10)
      
      {:ok, _pid} = Coordinator.start_link(max_slots: 10)
      
      # Attach telemetry handler
      test_pid = self()
      :telemetry.attach(
        "test-schedule",
        [:cybernetic, :s2, :coordinator, :schedule],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, :schedule, measurements, metadata})
        end,
        nil
      )
      
      Coordinator.set_priority(:test, 1.0)
      assert Coordinator.reserve_slot(:test) == :ok
      
      assert_receive {:telemetry, :schedule, measurements, metadata}, 1000
      assert measurements.reserved == 1
      assert metadata.topic == :test
      
      :telemetry.detach("test-schedule")
    end
    
    test "emits pressure event on backpressure" do
      case Process.whereis(Coordinator) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 100)
      end
      Process.sleep(10)
      
      {:ok, _pid} = Coordinator.start_link(max_slots: 1)
      
      # Attach telemetry handler
      test_pid = self()
      :telemetry.attach(
        "test-pressure",
        [:cybernetic, :s2, :coordinator, :pressure],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, :pressure, measurements, metadata})
        end,
        nil
      )
      
      Coordinator.set_priority(:test, 1.0)
      
      # Fill the slot
      assert Coordinator.reserve_slot(:test) == :ok
      
      # Should get backpressure
      assert Coordinator.reserve_slot(:test) == :backpressure
      
      assert_receive {:telemetry, :pressure, measurements, metadata}, 1000
      assert measurements.current == 1
      assert metadata.topic == :test
      
      :telemetry.detach("test-pressure")
    end
  end
end