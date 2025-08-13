defmodule Cybernetic.VSM.System2.Coordination do
  use GenServer
  require Logger
  def start_link(_), do: GenServer.start_link(__MODULE__, %{attention: %{}}, name: __MODULE__)

  def init(s), do: {:ok, s}

  def handle_info({:attention, :telegram, chat, text}, s) do
    # Simple attention weighting demo; send to S4 for reasoning
    send(Cybernetic.VSM.System4.Intelligence, {:analyze, :telegram, chat, text})
    {:noreply, s}
  end
end
