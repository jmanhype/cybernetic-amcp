defmodule Cybernetic.Core.CRDT.Graph do
  @moduledoc """
  DeltaCRDT-backed semantic context graph.
  """
  alias DeltaCrdt, as: D

  @store Cybernetic.Context.GraphStore

  def put(key, val), do: D.mutate(@store, :add, [key, %{val: val, ts: System.system_time(:millisecond)}])
  def get_all(), do: D.read(@store)
end
