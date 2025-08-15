defmodule Cybernetic.VSM.System4.LLMBridgeTest do
  use ExUnit.Case

  defmodule Dummy do
    @behaviour Cybernetic.VSM.System4.LLMProvider
    def analyze_episode(ep, _), do: {:ok, %{summary: "ok #{ep["id"]}", recommendations: [], sop_suggestions: []}}
  end

  test "consumes episode and calls provider" do
    {:ok, _} = start_supervised({Cybernetic.VSM.System5.SOPEngine, []})
    {:ok, pid} = start_supervised({Cybernetic.VSM.System4.LLMBridge, provider: Dummy, subscribe: fn p -> send(p, {:episode, %{"id" => "e1"}}) end})
    assert is_pid(pid)
  end
end