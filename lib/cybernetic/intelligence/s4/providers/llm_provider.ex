defmodule Cybernetic.Intelligence.S4.Providers.LLMProvider do
  @moduledoc "Contract for LLM backends used by System 4."
  @type prompt :: binary()
  @type opts :: Keyword.t()
  @callback complete(prompt(), opts) :: {:ok, binary()} | {:error, term()}
end