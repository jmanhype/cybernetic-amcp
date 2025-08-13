defmodule Cybernetic.Core.Transport.AMQP.Connection do
  @moduledoc """
  Alias to the main AMQP Connection for backward compatibility.
  """
  
  defdelegate reconnect(), to: Cybernetic.Transport.AMQP.Connection
  defdelegate get_channel(), to: Cybernetic.Transport.AMQP.Connection
end