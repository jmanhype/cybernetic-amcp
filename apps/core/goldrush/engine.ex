
defmodule Cybernetic.Core.Goldrush.Engine do
  @moduledoc """
  Goldrush stream engine integration (plugins/telemetry/elixir branches).
  """
  use GenServer
  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    # Wire Telemetry/Plugins once goldrush API is available.
    {:ok, %{rules: []}}
  end

  @doc """
  Register a pattern-matching rule.
  """
  def register_rule(rule), do: GenServer.call(__MODULE__, {:register, rule})
  def handle_call({:register, rule}, _from, state), do: {:reply, :ok, %{state | rules: [rule | state.rules]}}
end
