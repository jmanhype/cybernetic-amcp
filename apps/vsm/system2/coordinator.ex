
defmodule Cybernetic.System2.Coordinator do
  @moduledoc """
  Attention/coordination engine (Layer 6B-inspired).
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{attention: %{}}, name: __MODULE__)

  def focus(task_id), do: GenServer.cast(__MODULE__, {:focus, task_id})
  def weight(task_id), do: GenServer.call(__MODULE__, {:weight, task_id})

  def handle_cast({:focus, task_id}, %{attention: att} = state) do
    info = Map.get(att, task_id, %{w: 1.0})
    {:noreply, %{state | attention: Map.put(att, task_id, %{w: info.w * 1.05})}}
  end

  def handle_call({:weight, task_id}, _from, %{attention: att} = state) do
    {:reply, Map.get(att, task_id, %{w: 1.0}).w, state}
  end
end
