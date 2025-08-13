defmodule Cybernetic.VSM.System1.TelegramAgent do
  @moduledoc """
  S1 entrypoint for Telegram messages; routes to S2–S4 and CRDT context.
  """
  use GenServer
  alias Cybernetic.Core.CRDT.Graph, as: Context
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    # Polling loop could be replaced by webhook in production
    if token = System.get_env("TELEGRAM_BOT_TOKEN") do
      Logger.info("TelegramAgent ready (token present)")
    else
      Logger.warning("TELEGRAM_BOT_TOKEN missing — bot disabled")
    end
    {:ok, state}
  end

  # Example public API to process an inbound message
  def handle_message(%{chat_id: chat, text: text}) do
    Context.put({:chat, chat, :last_text}, text)
    send(Cybernetic.VSM.System2.Coordination, {:attention, :telegram, chat, text})
  end
end
