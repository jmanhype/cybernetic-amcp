
defmodule Cybernetic.VSM.System1.Operational do
  use Supervisor
  @moduledoc """
  S1: Entry points, AMQP workers, Telegram agent, etc.
  """

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Cybernetic.VSM.System1.AgentSupervisor, strategy: :one_for_one}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
  
  # Test interface - routes messages through the message handler
  def handle_message(message, meta \\ %{}) do
    operation = Map.get(message, :operation, "unknown")
    Cybernetic.VSM.System1.MessageHandler.handle_message(operation, message, meta)
  end
end
