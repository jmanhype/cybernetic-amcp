defmodule Cybernetic.Core.CRDT.ContextGraphTest do
  use ExUnit.Case, async: true
  alias Cybernetic.Core.CRDT.ContextGraph

  describe "ContextGraph" do
    setup do
      # Start a new ContextGraph for each test
      {:ok, pid} = ContextGraph.start_link()
      {:ok, graph: pid}
    end

    test "stores and retrieves semantic triples", %{graph: _graph} do
      # Store a triple
      subject = "Alice"
      predicate = "knows"
      object = "Bob"
      meta = %{confidence: 0.9, source: "test"}
      
      assert :ok = ContextGraph.put_triple(subject, predicate, object, meta)
      
      # Give CRDT time to sync
      Process.sleep(100)
      
      # Query all triples
      triples = ContextGraph.query([])
      
      assert length(triples) > 0
      
      # Find our triple
      triple = Enum.find(triples, fn t ->
        t.subject == subject && t.predicate == predicate && t.object == object
      end)
      
      assert triple != nil
      assert triple.subject == subject
      assert triple.predicate == predicate
      assert triple.object == object
      assert triple.meta.confidence == 0.9
      assert triple.meta.source == "test"
      assert is_integer(triple.meta.timestamp)
    end

    test "stores multiple triples", %{graph: _graph} do
      # Store multiple relationships
      triples = [
        {"Alice", "knows", "Bob", %{weight: 1.0}},
        {"Alice", "knows", "Charlie", %{weight: 0.8}},
        {"Bob", "works_with", "Charlie", %{weight: 0.5}},
        {"Charlie", "manages", "Dave", %{weight: 1.0}}
      ]
      
      for {s, p, o, m} <- triples do
        assert :ok = ContextGraph.put_triple(s, p, o, m)
      end
      
      # Give CRDT time to sync
      Process.sleep(100)
      
      # Query all triples
      stored_triples = ContextGraph.query([])
      
      assert length(stored_triples) == 4
      
      # Verify all subjects are present
      subjects = stored_triples |> Enum.map(& &1.subject) |> Enum.uniq() |> Enum.sort()
      assert subjects == ["Alice", "Bob", "Charlie"]
    end

    test "handles concurrent updates", %{graph: _graph} do
      # Simulate concurrent updates
      tasks = for i <- 1..10 do
        Task.async(fn ->
          ContextGraph.put_triple(
            "Node#{i}", 
            "connects_to", 
            "Node#{rem(i + 1, 10)}", 
            %{index: i}
          )
        end)
      end
      
      # Wait for all tasks
      Enum.each(tasks, &Task.await/1)
      
      # Give CRDT time to converge
      Process.sleep(200)
      
      # Query all triples
      triples = ContextGraph.query([])
      
      # Should have all 10 connections
      assert length(triples) == 10
      
      # Verify each node is present
      nodes = triples 
        |> Enum.flat_map(fn t -> [t.subject, t.object] end)
        |> Enum.uniq()
        |> Enum.sort()
      
      expected_nodes = for i <- 0..9, do: "Node#{i}"
      assert nodes == Enum.sort(expected_nodes)
    end

    test "metadata includes timestamp", %{graph: _graph} do
      before = System.system_time(:millisecond)
      
      assert :ok = ContextGraph.put_triple("A", "relates", "B")
      
      after_time = System.system_time(:millisecond)
      
      Process.sleep(100)
      
      triples = ContextGraph.query([])
      triple = List.first(triples)
      
      assert triple.meta.timestamp >= before
      assert triple.meta.timestamp <= after_time
    end

    test "handles special characters in triples", %{graph: _graph} do
      # Test with various special characters
      subject = "User:alice@example.com"
      predicate = "has-permission"
      object = "/path/to/resource?query=1&flag=true"
      meta = %{permission_level: "read/write", expires: "2024-12-31"}
      
      assert :ok = ContextGraph.put_triple(subject, predicate, object, meta)
      
      Process.sleep(100)
      
      triples = ContextGraph.query([])
      triple = List.first(triples)
      
      assert triple.subject == subject
      assert triple.predicate == predicate
      assert triple.object == object
      assert triple.meta.permission_level == "read/write"
    end
  end
end