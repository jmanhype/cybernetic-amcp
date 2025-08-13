defmodule Cybernetic.Telegram.Supervisor do
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts) do
    children = [
      Cybernetic.Telegram.Bot.Agent
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
