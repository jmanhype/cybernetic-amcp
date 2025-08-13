defmodule Cybernetic.Telegram.Bot.Agent do
  @moduledoc """
  S1 entrypoint: receives Telegram updates (placeholder), routes to S4 as needed.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(st), do: {:ok, st}

  # Example entrypoint from webhook/controller wiring:
  def handle_cast({:incoming_msg, chat_id, text}, st) do
    # Context enrichment into CRDT graph
    Cybernetic.Core.CRDT.ContextGraph.put_triple({:chat, chat_id}, :said, text, %{source: :telegram})
    # Attention focus on this chat/task
    Cybernetic.VSM.System2.Coordinator.focus({:chat, chat_id})
    # Route to S4 if needed
    {:ok, _} = Cybernetic.VSM.System4.Intelligence.analyze(text)
    {:noreply, st}
  end
end
