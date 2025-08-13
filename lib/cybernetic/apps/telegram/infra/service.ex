
defmodule Cybernetic.Telegram.Infra.Service do
  @moduledoc """
  HTTP bridge/webhook placeholder; add real Telegram client.
  """
  def push_update(update), do: GenServer.cast(Cybernetic.Telegram.Agent, {:incoming_message, update})
end
