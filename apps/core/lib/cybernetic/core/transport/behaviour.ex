defmodule Cybernetic.Transport do
  @callback publish(exchange :: String.t(), routing_key :: String.t(), payload :: iodata(), meta :: map()) :: :ok | {:error, term()}
end
