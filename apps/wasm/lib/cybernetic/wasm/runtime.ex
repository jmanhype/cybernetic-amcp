defmodule Cybernetic.WASM.Runtime do
  @moduledoc """
  Sandboxed execution of policy plugins in WASM (wasmex wrapper).
  """
  def run(_wasm_bytes, _func, _args), do: {:ok, :not_implemented}
end
