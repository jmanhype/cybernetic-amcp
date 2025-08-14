defmodule Cybernetic.Edge.WASM.Validator do
  @moduledoc "Behaviour-backed validator that delegates to a WASM module."
  @behaviour Cybernetic.Edge.WASM.Behaviours.Validator
  alias Cybernetic.Edge.WASM.ValidatorHost

  @impl true
  def init(opts), do: {:ok, %{server: opts[:server] || ValidatorHost}}

  @impl true
  def validate(message, %{server: server} = state) do
    case ValidatorHost.validate(server, message) do
      :ok -> {:ok, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end
end