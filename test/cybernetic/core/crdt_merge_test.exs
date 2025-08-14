defmodule Cybernetic.Core.CRDTMergeTest do
  use ExUnit.Case
  
  alias DeltaCrdt.AWLWWMap
  
  test "converges regardless of order" do
    # Create two CRDT instances
    {:ok, a} = DeltaCrdt.start_link(AWLWWMap, sync_interval: 10)
    {:ok, b} = DeltaCrdt.start_link(AWLWWMap, sync_interval: 10)
    
    # Set them as neighbors
    DeltaCrdt.set_neighbours(a, [b])
    DeltaCrdt.set_neighbours(b, [a])
    
    # Add conflicting data to both
    DeltaCrdt.put(a, "session:42", %{token: 1, user: "alice"})
    DeltaCrdt.put(b, "session:42", %{token: 2, user: "bob"})
    
    # Add non-conflicting data
    DeltaCrdt.put(a, "config:db", %{host: "localhost"})
    DeltaCrdt.put(b, "config:cache", %{ttl: 300})
    
    # Wait for sync
    Process.sleep(50)
    
    # Read both states
    state_a = DeltaCrdt.to_map(a)
    state_b = DeltaCrdt.to_map(b)
    
    # They should have converged to the same state
    assert state_a == state_b
    
    # Both should have all keys
    assert Map.has_key?(state_a, "session:42")
    assert Map.has_key?(state_a, "config:db")
    assert Map.has_key?(state_a, "config:cache")
    
    # Clean up
    Process.unlink(a)
    Process.unlink(b)
    DeltaCrdt.stop(a)
    DeltaCrdt.stop(b)
  end
  
  test "idempotent operations" do
    {:ok, crdt} = DeltaCrdt.start_link(AWLWWMap, sync_interval: 1000)
    
    # Add the same value multiple times
    DeltaCrdt.mutate(crdt, :add, ["key1", %{value: "test"}])
    state1 = DeltaCrdt.read(crdt)
    
    DeltaCrdt.mutate(crdt, :add, ["key1", %{value: "test"}])
    state2 = DeltaCrdt.read(crdt)
    
    DeltaCrdt.mutate(crdt, :add, ["key1", %{value: "test"}])
    state3 = DeltaCrdt.read(crdt)
    
    # State should be identical after repeated operations
    assert state1 == state2
    assert state2 == state3
    
    # Clean up
    Process.unlink(crdt)
    DeltaCrdt.stop(crdt)
  end
  
  test "commutative merge" do
    {:ok, a} = DeltaCrdt.start_link(AWLWWMap, sync_interval: 1000)
    {:ok, b} = DeltaCrdt.start_link(AWLWWMap, sync_interval: 1000)
    {:ok, c} = DeltaCrdt.start_link(AWLWWMap, sync_interval: 10)
    
    # Add data in different order
    DeltaCrdt.mutate(a, :add, ["x", 1])
    DeltaCrdt.mutate(a, :add, ["y", 2])
    
    DeltaCrdt.mutate(b, :add, ["y", 2])
    DeltaCrdt.mutate(b, :add, ["x", 1])
    
    # C merges from both A and B
    DeltaCrdt.set_neighbours(c, [a, b])
    DeltaCrdt.set_neighbours(a, [c])
    DeltaCrdt.set_neighbours(b, [c])
    
    # Wait for convergence
    Process.sleep(50)
    
    state_a = DeltaCrdt.read(a)
    state_b = DeltaCrdt.read(b)
    state_c = DeltaCrdt.read(c)
    
    # All should converge to same state
    assert state_a == state_b
    assert state_b == state_c
    
    # Clean up
    Process.unlink(a)
    Process.unlink(b)
    Process.unlink(c)
    DeltaCrdt.stop(a)
    DeltaCrdt.stop(b)
    DeltaCrdt.stop(c)
  end
  
  test "remove operations converge" do
    {:ok, a} = DeltaCrdt.start_link(AWLWWMap, sync_interval: 10)
    {:ok, b} = DeltaCrdt.start_link(AWLWWMap, sync_interval: 10)
    
    DeltaCrdt.set_neighbours(a, [b])
    DeltaCrdt.set_neighbours(b, [a])
    
    # Both add the same key
    DeltaCrdt.mutate(a, :add, ["temp", %{data: "value"}])
    Process.sleep(20)
    
    # A removes it
    DeltaCrdt.mutate(a, :remove, ["temp"])
    
    # B updates it (concurrent with remove)
    DeltaCrdt.mutate(b, :add, ["temp", %{data: "updated"}])
    
    # Wait for convergence
    Process.sleep(50)
    
    state_a = DeltaCrdt.read(a)
    state_b = DeltaCrdt.read(b)
    
    # Should converge (last-write-wins or remove-wins depending on timestamps)
    assert state_a == state_b
    
    # Clean up
    Process.unlink(a)
    Process.unlink(b)
    DeltaCrdt.stop(a)
    DeltaCrdt.stop(b)
  end
end