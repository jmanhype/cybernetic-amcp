defmodule Cybernetic.VSM.System2.CoordinatorTest do
  use ExUnit.Case
  alias Cybernetic.VSM.System2.Coordinator

  setup do
    # Coordinator is started by the application, just use it
    {:ok, coordinator: Process.whereis(Coordinator)}
  end

  describe "priority queue methods" do
    test "sets priority weights for topics" do
      Coordinator.set_priority("high_priority", 2.0)
      Coordinator.set_priority("low_priority", 0.5)
      
      # Verify by attempting slot reservation
      assert :ok = Coordinator.reserve_slot("high_priority")
    end

    test "reserves slots based on priority" do
      # Set different priorities
      Coordinator.set_priority("critical", 3.0)
      Coordinator.set_priority("normal", 1.0)
      
      # Critical should get more slots
      for _ <- 1..6 do
        assert :ok = Coordinator.reserve_slot("critical")
      end
      
      # Normal gets fewer slots
      for _ <- 1..2 do
        assert :ok = Coordinator.reserve_slot("normal")
      end
      
      # Eventually hits backpressure
      assert :backpressure = Coordinator.reserve_slot("normal")
    end

    test "releases slots correctly" do
      topic = "test_topic"
      Coordinator.set_priority(topic, 1.0)
      
      # Reserve all slots
      for _ <- 1..8 do
        assert :ok = Coordinator.reserve_slot(topic)
      end
      
      # Should hit backpressure
      assert :backpressure = Coordinator.reserve_slot(topic)
      
      # Release a slot
      Coordinator.release_slot(topic)
      Process.sleep(10)
      
      # Should be able to reserve again
      assert :ok = Coordinator.reserve_slot(topic)
    end

    test "handles multiple topics independently" do
      Coordinator.set_priority("api", 2.0)
      Coordinator.set_priority("background", 0.5)
      
      # Reserve slots for api
      for _ <- 1..8 do
        Coordinator.reserve_slot("api")
      end
      
      # Background should still have slots
      assert :ok = Coordinator.reserve_slot("background")
    end

    test "focus increases attention weight" do
      task_id = "important_task"
      
      # Focus multiple times
      Coordinator.focus(task_id)
      Process.sleep(5)
      Coordinator.focus(task_id)
      Process.sleep(5)
      Coordinator.focus(task_id)
      
      # State is internal, but we can verify it doesn't crash
      assert Process.alive?(Process.whereis(Coordinator))
    end

    test "handles concurrent slot reservations" do
      topic = "concurrent_test"
      Coordinator.set_priority(topic, 1.0)
      
      # Spawn multiple processes trying to reserve slots
      tasks = for _ <- 1..20 do
        Task.async(fn ->
          Coordinator.reserve_slot(topic)
        end)
      end
      
      results = Task.await_many(tasks)
      
      # Count successful reservations
      successful = Enum.count(results, &(&1 == :ok))
      backpressured = Enum.count(results, &(&1 == :backpressure))
      
      assert successful == 8  # max_slots default
      assert backpressured == 12
    end

    test "priority affects slot allocation proportionally" do
      # Set up topics with different priorities
      Coordinator.set_priority("gold", 4.0)
      Coordinator.set_priority("silver", 2.0)
      Coordinator.set_priority("bronze", 1.0)
      
      # Gold should get most slots (proportional to priority)
      gold_slots = Enum.count(1..8, fn _ ->
        Coordinator.reserve_slot("gold") == :ok
      end)
      
      silver_slots = Enum.count(1..8, fn _ ->
        Coordinator.reserve_slot("silver") == :ok
      end)
      
      bronze_slots = Enum.count(1..8, fn _ ->
        Coordinator.reserve_slot("bronze") == :ok
      end)
      
      # Gold should get the most slots
      assert gold_slots >= silver_slots
      assert silver_slots >= bronze_slots
    end
  end
end