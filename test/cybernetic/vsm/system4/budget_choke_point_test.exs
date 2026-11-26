defmodule Cybernetic.VSM.BudgetChokePointTest do
  @moduledoc """
  Couplings #1–#2 (Axiomatic Design register): every inference path
  must pass the S3 budget choke point, and the S3 RateLimiter must be
  the only budget DP. These tests drain the :s4_llm budget and prove
  that LLMBridge, PolicyIntelligence, and Service are all denied —
  before the fix, LLMBridge and PolicyIntelligence called providers
  directly and Service consulted a different limiter with the budget
  key passed as the token count.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.VSM.System3.RateLimiter
  alias Cybernetic.VSM.System4.{Episode, LLMBridge, Service}
  alias Cybernetic.VSM.System5.PolicyIntelligence

  setup do
    RateLimiter.reset_budget(:s4_llm)
    on_exit(fn -> RateLimiter.reset_budget(:s4_llm) end)
    :ok
  end

  # Drain with :critical priority (cost 1 per request): the limiter
  # charges by priority (:normal costs 2, :low 4), so draining at a
  # higher cost can stop at 99/100 and still admit a cost-1 request.
  defp drain_budget do
    Enum.reduce_while(1..300, :ok, fn _, _ ->
      case RateLimiter.request_tokens(:s4_llm, :test, :critical) do
        :ok -> {:cont, :ok}
        {:error, :rate_limited} -> {:halt, :drained}
      end
    end)

    assert {:error, :rate_limited} = RateLimiter.request_tokens(:s4_llm, :test, :critical)
  end

  test "LLMBridge routes through the Router and is denied when the budget is drained" do
    test_pid = self()
    handler = "choke-point-bridge-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:cybernetic, :s4, :llm, :response],
        [:cybernetic, :s4, :llm, :error]
      ],
      fn event, _measurements, _metadata, _config ->
        send(test_pid, {:llm_event, List.last(event)})
      end,
      %{}
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    start_supervised!(
      {LLMBridge, subscribe: fn _pid -> :ok end, router_opts: [override_chain: [:null]]}
    )

    episode = %{"id" => "choke-ep-1", "type" => "anomaly_detection", "severity" => "high"}

    GenServer.cast(LLMBridge, {:episode, episode})
    assert_receive {:llm_event, :response}, 5_000

    drain_budget()

    GenServer.cast(LLMBridge, {:episode, episode})
    assert_receive {:llm_event, :error}, 5_000
  end

  test "PolicyIntelligence is denied by the budget instead of calling the provider directly" do
    start_supervised!({PolicyIntelligence, anthropic: [api_key: "test-key"]})

    drain_budget()

    # Call the GenServer directly with a generous timeout: the
    # Router's fallback backoff sleeps between the three denied
    # providers, which can exceed the public API's 5s call timeout.
    assert {:error, :all_providers_failed} =
             GenServer.call(
               PolicyIntelligence,
               {:recommend_governance, %{"type" => "test"}, []},
               20_000
             )
  end

  test "Service consults the S3 budget (not the security rate limiter)" do
    if Process.whereis(Service) == nil do
      # Service's circuit breakers register in this Registry, which
      # the full supervision tree provides but minimal test mode does
      # not.
      if Process.whereis(Cybernetic.Core.Resilience.AdaptiveCircuitBreaker.Registry) == nil do
        start_supervised!(
          {Registry,
           keys: :unique, name: Cybernetic.Core.Resilience.AdaptiveCircuitBreaker.Registry}
        )
      end

      start_supervised!({Cybernetic.VSM.System4.Memory, []})
      start_supervised!({Service, providers: [:anthropic]})
    end

    episode = Episode.new(:classification, "choke point probe", %{}, priority: :normal)

    # Only the drained case is asserted: with budget available the
    # request proceeds to the real (unconfigured) providers, whose
    # failure modes are outside this test's concern. Drained, the S3
    # check must deny before any provider is attempted — if Service
    # still consulted the old security limiter, the drained S3
    # budget would not deny it.
    drain_budget()

    assert {:error, message} = Service.analyze_episode(episode)
    assert message =~ "Rate limited"
  end
end
