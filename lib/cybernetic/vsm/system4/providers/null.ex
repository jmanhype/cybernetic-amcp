defmodule Cybernetic.VSM.System4.Providers.Null do
  @moduledoc "No-op provider that echoes placeholders; useful for tests/dev."
  @behaviour Cybernetic.VSM.System4.LLMProvider

  @impl true
  def analyze_episode(ep, _opts) do
    {:ok,
     %{
       summary: "noop summary for #{ep["id"] || "episode"}",
       recommendations: [],
       sop_suggestions: []
     }}
  end
end