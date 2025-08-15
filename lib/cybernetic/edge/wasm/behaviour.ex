defmodule Cybernetic.Edge.WASM.Behaviour do
  @moduledoc """
  Contract for WASM validators used at the edge. Implementations must be pure
  and side-effect free, returning only :ok | {:error, reason}.
  """
  @callback load(module_bytes :: binary(), opts :: keyword) ::
              {:ok, term()} | {:error, term()}
  @callback validate(instance :: term(), message :: map(), opts :: keyword) ::
              :ok | {:error, term()}
end