defmodule Cybernetic.VSM.System5.Identity do
  use GenServer
  @moduledoc """
  S5 defines goals/policies and can spawn recursive meta-systems.
  """
  def start_link(_), do: GenServer.start_link(__MODULE__, %{policies: %{}}, name: __MODULE__)
  def init(s), do: {:ok, s}
end
