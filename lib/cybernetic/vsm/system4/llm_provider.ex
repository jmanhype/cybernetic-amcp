defmodule Cybernetic.VSM.System4.LLMProvider do
  @moduledoc """
  Provider contract for S4 LLM Bridge. Implement a thin adapter per vendor.
  """
  @callback analyze_episode(episode :: map(), opts :: keyword) ::
              {:ok, %{summary: String.t(), recommendations: [map()], sop_suggestions: [map()]}}
              | {:error, term()}
end