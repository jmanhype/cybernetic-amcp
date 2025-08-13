
defmodule Cybernetic.Telegram.Supervisor do
  @moduledoc """
  Boots Telegram stack only if TELEGRAM_BOT_TOKEN is present.
  """
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts) do
    if System.get_env("TELEGRAM_BOT_TOKEN") in [nil, ""] do
      Supervisor.init([], strategy: :one_for_one)
    else
      Supervisor.init([Cybernetic.Telegram.Agent], strategy: :one_for_one)
    end
  end
end
