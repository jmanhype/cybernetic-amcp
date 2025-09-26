defmodule Cybernetic.Core.Transport.AMQP.Connection do
  @moduledoc """
  Alias to the main AMQP Connection for backward compatibility.
  """

  def reconnect do
    Cybernetic.Transport.AMQP.Connection.reconnect()
  end

  def get_channel do
    Cybernetic.Transport.AMQP.Connection.get_channel()
  end
end
