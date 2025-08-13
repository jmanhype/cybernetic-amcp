defmodule Cybernetic.VSM.System1.Ops do
  use Supervisor
  def start_link(_), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  def init(:ok), do: Supervisor.init([Cybernetic.VSM.System1.TelegramAgent], strategy: :one_for_one)
end
