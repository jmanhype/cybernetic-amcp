defmodule Cybernetic.Transport.AMQP.Routes do
  use GenServer
  alias Cybernetic.Transport.AMQP.Connection

  @exchanges [
    {"cyb.events", :topic},
    {"cyb.commands", :topic},
    {"cyb.telemetry", :topic}
  ]

  def start_link(_), do: GenServer.start_link(__MODULE__, %{} , name: __MODULE__)

  def init(state) do
    with {:ok, chan} <- Connection.channel() do
      Enum.each(@exchanges, fn {name, type} -> AMQP.Exchange.declare(chan, name, type, durable: true) end)
    end
    {:ok, state}
  end
end
