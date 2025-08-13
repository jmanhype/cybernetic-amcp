
defmodule Cybernetic.Context.Graph do
  @moduledoc """
  Delta-CRDT powered semantic context store.
  """
  def start_link() do
    DeltaCrdt.start_link(DeltaCrdt.AWLWWMap, crdt_options())
  end
  defp crdt_options, do: [sync_interval: 25, ship_interval: 25, ship_debounce: 5]
end
