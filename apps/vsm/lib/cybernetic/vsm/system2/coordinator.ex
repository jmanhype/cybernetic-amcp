defmodule Cybernetic.VSM.System2.Coordinator do
  @moduledoc """
  Attention/coordination engine (Layer 6B-inspired facilitation).
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{attention: %{}}, name: __MODULE__)
  def init(st), do: {:ok, st}

  def focus(task_id), do: GenServer.cast(__MODULE__, {:focus, task_id})
  def weight_for(task_id), do: GenServer.call(__MODULE__, {:weight_for, task_id})

  def handle_cast({:focus, task_id}, %{attention: att} = st) do
    now = System.system_time(:millisecond)
    next = Map.update(att, task_id, %{weight: 1.1, last_seen: now}, fn m -> %{m | weight: m.weight * 1.05, last_seen: now} end)
    {:noreply, %{st | attention: next}}
  end

  def handle_call({:weight_for, id}, _from, %{attention: att} = st) do
    {:reply, get_in(att, [id, :weight]) || 1.0, st}
  end
end
