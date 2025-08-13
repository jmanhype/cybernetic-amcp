defmodule Cybernetic.Telegram.Infra.ResilientClient do
  @moduledoc """
  Fault-tolerant Telegram client wrapper.
  """
  def send_message(chat_id, text) do
    with {:ok, _} <- Nadia.send_message(chat_id, text) do
      :ok
    else
      _ -> :timer.sleep(500); Nadia.send_message(chat_id, text)
    end
  end
end
