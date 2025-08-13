defmodule Cybernetic.Telegram.Bot.CommandRouter do
  @moduledoc """
  Routes Telegram commands to VSM systems.
  """
  def route(%{chat_id: chat, text: "/help"}), do: {:reply, chat, "Help coming soon"}
  def route(%{chat_id: chat, text: text}), do: Cybernetic.VSM.System1.TelegramAgent.handle_message(%{chat_id: chat, text: text})
end
