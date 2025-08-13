
defmodule Cybernetic.Transport.AMQP.Topology do
  @moduledoc """
  Declare exchanges/queues/bindings for aMCP flows.
  """
  def declare(chan) do
    # Example durable topic for context events
    AMQP.Exchange.declare(chan, "amcp.context", :topic, durable: true)
    :ok
  end
end
