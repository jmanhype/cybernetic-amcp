
defmodule Cybernetic.Plugin do
  @moduledoc """
  Contract for domain-specific handlers that can be loaded at runtime.
  """
  @callback init(opts :: map()) :: {:ok, state :: term()} | {:error, term()}
  @callback handle_event(event :: map(), state :: term()) :: {:ok, new_state :: term()}
  @callback metadata() :: map()
end
