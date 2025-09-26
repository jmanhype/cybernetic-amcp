defmodule Cybernetic.Core.CRDT.ContextGraphTest do
  use ExUnit.Case
  alias Cybernetic.Core.CRDT.ContextGraph

  setup do
    # Start a fresh instance for each test
    case Process.whereis(ContextGraph) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, pid} = ContextGraph.start_link()
    {:ok, graph: pid}
  end

  describe "distributed sync" do
    test "initializes with node monitoring enabled" do
      # The module sets up node monitoring in init
      # We can verify by checking the process is alive
      assert Process.alive?(Process.whereis(ContextGraph))
    end

    test "enables sync manually" do
      # This should trigger :wire_neighbors message
      ContextGraph.enable_sync()

      # Give it time to process
      Process.sleep(50)

      # Should not crash
      assert Process.alive?(Process.whereis(ContextGraph))
    end

    test "gets current neighbors" do
      neighbors = ContextGraph.get_neighbors()

      # Initially empty (no other nodes)
      assert is_list(neighbors)
      assert neighbors == []
    end

    test "handles nodeup events" do
      # Simulate a nodeup event
      send(ContextGraph, {:nodeup, :test@node, %{}})

      Process.sleep(50)

      # Should not crash
      assert Process.alive?(Process.whereis(ContextGraph))
    end

    test "handles nodedown events" do
      # Simulate a nodedown event
      send(ContextGraph, {:nodedown, :test@node, %{}})

      Process.sleep(50)

      # Should not crash
      assert Process.alive?(Process.whereis(ContextGraph))
    end

    test "wires neighbors when requested" do
      # Send wire_neighbors message
      send(ContextGraph, :wire_neighbors)

      Process.sleep(50)

      # Should complete without error
      neighbors = ContextGraph.get_neighbors()
      assert is_list(neighbors)
    end
  end

  describe "triple storage with sync" do
    test "stores and retrieves triples while sync is enabled" do
      # Enable sync
      ContextGraph.enable_sync()

      # Store a triple
      ContextGraph.put_triple("user123", "likes", "elixir", %{confidence: 0.9})

      Process.sleep(50)

      # Query it back
      results = ContextGraph.query(subject: "user123")

      assert length(results) == 1
      assert hd(results).predicate == "likes"
      assert hd(results).object == "elixir"
    end

    test "handles concurrent operations with sync" do
      # Enable sync
      ContextGraph.enable_sync()

      # Concurrent writes
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            ContextGraph.put_triple("entity#{i}", "type", "test", %{index: i})
          end)
        end

      Task.await_many(tasks)
      Process.sleep(50)

      # Query all
      results = ContextGraph.query(%{})

      assert length(results) >= 10
    end

    test "maintains data integrity during node events" do
      # Store initial data
      ContextGraph.put_triple("persistent", "remains", "intact")

      # Simulate node events
      send(ContextGraph, {:nodeup, :new@node, %{}})
      Process.sleep(10)
      send(ContextGraph, {:nodedown, :new@node, %{}})
      Process.sleep(10)
      send(ContextGraph, :wire_neighbors)
      Process.sleep(10)

      # Data should still be there
      results = ContextGraph.query(subject: "persistent")

      assert length(results) == 1
      assert hd(results).object == "intact"
    end
  end

  describe "neighbor management" do
    test "tracks neighbors correctly" do
      # Initially no neighbors
      assert ContextGraph.get_neighbors() == []

      # Wire neighbors (will find no other nodes in test)
      send(ContextGraph, :wire_neighbors)
      Process.sleep(50)

      # Still empty in single-node test
      assert ContextGraph.get_neighbors() == []
    end

    test "handles multiple wire_neighbors calls" do
      # Multiple wiring attempts should not cause issues
      for _ <- 1..5 do
        send(ContextGraph, :wire_neighbors)
        Process.sleep(10)
      end

      assert Process.alive?(Process.whereis(ContextGraph))
      assert is_list(ContextGraph.get_neighbors())
    end

    test "survives rapid node events" do
      # Rapid node up/down events
      for i <- 1..10 do
        node = :"node#{i}@test"
        send(ContextGraph, {:nodeup, node, %{}})
        send(ContextGraph, {:nodedown, node, %{}})
      end

      Process.sleep(100)

      # Should handle gracefully
      assert Process.alive?(Process.whereis(ContextGraph))
    end
  end

  describe "sync timing" do
    test "schedules wire_neighbors after init" do
      # Restart to observe init behavior
      GenServer.stop(ContextGraph)
      {:ok, _pid} = ContextGraph.start_link()

      # Should schedule :wire_neighbors for 1 second later
      # We can't directly test this, but verify it doesn't crash
      Process.sleep(1100)

      assert Process.alive?(Process.whereis(ContextGraph))
    end

    test "re-wires on nodeup with delay" do
      # Send nodeup
      send(ContextGraph, {:nodeup, :new@node, %{}})

      # Should schedule re-wiring for 500ms later
      Process.sleep(600)

      assert Process.alive?(Process.whereis(ContextGraph))
    end
  end
end
