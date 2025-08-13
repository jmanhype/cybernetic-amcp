defmodule Cybernetic.Transport.AMQP.Supervisor do
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  def init(:ok) do
    children = [
      Cybernetic.Transport.AMQP.Connection,
      Cybernetic.Transport.AMQP.Routes,
      Cybernetic.Transport.AMQP.Causality
    ]
    Supervisor.init(children, strategy: :one_for_all)
  end
end
