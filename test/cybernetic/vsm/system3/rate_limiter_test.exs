defmodule Cybernetic.VSM.System3.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Cybernetic.VSM.System3.RateLimiter

  test "resets consumed budget after the window passes" do
    {:ok, pid} =
      start_supervised(
        {RateLimiter,
         name: nil,
         default_budgets: %{
           test_budget: %{limit: 2, window_ms: 10}
         }}
      )

    assert :ok = RateLimiter.request_tokens(pid, :test_budget, :any, :normal)
    assert {:error, :rate_limited} = RateLimiter.request_tokens(pid, :test_budget, :any, :normal)

    Process.sleep(25)

    assert :ok = RateLimiter.request_tokens(pid, :test_budget, :any, :normal)
  end
end
