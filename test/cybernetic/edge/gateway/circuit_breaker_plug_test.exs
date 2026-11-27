defmodule Cybernetic.Edge.Gateway.Plugs.CircuitBreakerTest do
  @moduledoc """
  Tests for coupling #10: the edge gateway circuit breaker plug must
  record request outcomes into the same AdaptiveCircuitBreaker it
  checks, so the breaker can actually trip.

  The plug is driven the way the `:api` pipeline composes it: the plug
  runs first, then the "downstream" (controller) runs unless the plug
  halted the conn, and the response is sent last — sending is what runs
  the plug's before-send recording callback.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Cybernetic.Core.Resilience.AdaptiveCircuitBreaker
  alias Cybernetic.Edge.Gateway.Plugs.CircuitBreaker

  @moduletag capture_log: true

  setup do
    # The full supervision tree provides the breakers' via Registry;
    # minimal test mode does not (same guard as the S4 budget tests).
    if Process.whereis(AdaptiveCircuitBreaker.Registry) == nil do
      start_supervised!({Registry, keys: :unique, name: AdaptiveCircuitBreaker.Registry})
    end

    breaker = :"edge_breaker_test_#{System.unique_integer([:positive])}"

    prev_environment = Application.get_env(:cybernetic, :environment)
    prev_edge_gateway = Application.get_env(:cybernetic, :edge_gateway)

    # The plug only enforces/records in :prod; point it at this test's
    # uniquely-named breaker instance.
    Application.put_env(:cybernetic, :environment, :prod)
    Application.put_env(:cybernetic, :edge_gateway, circuit_breaker_name: breaker)

    on_exit(fn ->
      restore_env(:environment, prev_environment)
      restore_env(:edge_gateway, prev_edge_gateway)
    end)

    {:ok, breaker: breaker}
  end

  test "repeated 5xx responses trip the breaker; open breaker rejects without reaching downstream",
       %{breaker: breaker} do
    start_breaker!(breaker, failure_threshold: 2)

    for _ <- 1..2 do
      conn = dispatch(conn(:post, "/v1/generate"), respond_with(500))
      assert conn.status == 500
      refute conn.halted
    end

    assert_eventually(fn -> breaker_state(breaker) == :open end)

    flush_downstream_markers()

    conn = dispatch(conn(:post, "/v1/generate"), respond_with(200, self()))
    assert conn.halted
    assert conn.status == 503
    assert conn.resp_body =~ "service_unavailable"
    refute_received :downstream_called
  end

  test "2xx, 3xx and 4xx responses are recorded as successes and never trip the breaker",
       %{breaker: breaker} do
    start_breaker!(breaker, failure_threshold: 2)

    for status <- [200, 404, 200, 404, 302] do
      conn = dispatch(conn(:post, "/v1/generate"), respond_with(status))
      assert conn.status == status
      refute conn.halted
    end

    assert_eventually(fn -> AdaptiveCircuitBreaker.get_state(breaker).success_count == 5 end)

    stats = AdaptiveCircuitBreaker.get_state(breaker)
    assert stats.failure_count == 0
    assert stats.state == :closed
  end

  test "after the recovery window, successful probes close the breaker and traffic flows again",
       %{breaker: breaker} do
    start_breaker!(breaker, failure_threshold: 2, success_threshold: 2, timeout_ms: 100)

    for _ <- 1..2 do
      dispatch(conn(:post, "/v1/generate"), respond_with(500))
    end

    assert_eventually(fn -> breaker_state(breaker) == :open end)
    # The breaker's own recovery timer moves it to half-open (~200 ms
    # backoff on a 100 ms timeout) — no production-duration sleeps.
    assert_eventually(fn -> breaker_state(breaker) == :half_open end)

    # First successful probe: counted, but below the success threshold.
    conn = dispatch(conn(:post, "/v1/generate"), respond_with(200))
    assert conn.status == 200
    assert_eventually(fn -> AdaptiveCircuitBreaker.get_state(breaker).success_count == 1 end)
    assert breaker_state(breaker) == :half_open

    # Second successful probe reaches the threshold: breaker closes.
    conn = dispatch(conn(:post, "/v1/generate"), respond_with(200))
    assert conn.status == 200
    assert_eventually(fn -> breaker_state(breaker) == :closed end)

    # Traffic flows again.
    conn = dispatch(conn(:post, "/v1/generate"), respond_with(200, self()))
    assert conn.status == 200
    assert_received :downstream_called
  end

  test "a downstream raise propagates and is recorded as a failure when the error response is sent",
       %{breaker: breaker} do
    start_breaker!(breaker, failure_threshold: 5)

    conn = conn(:post, "/v1/generate")
    conn = CircuitBreaker.call(conn, CircuitBreaker.init([]))
    refute conn.halted

    downstream = fn _conn -> raise "downstream boom" end
    assert_raise RuntimeError, "downstream boom", fn -> downstream.(conn) end

    # The plug returns before downstream runs, so it cannot swallow the
    # raise. The endpoint's error handling renders the 500 on this same
    # conn; sending it runs the plug's before-send recording callback.
    conn = send_resp(conn, 500, "Internal Server Error")
    assert conn.status == 500

    assert_eventually(fn -> AdaptiveCircuitBreaker.get_state(breaker).failure_count == 1 end)
    assert breaker_state(breaker) == :closed
  end

  test "in the test environment the plug passes through and records nothing",
       %{breaker: breaker} do
    Application.put_env(:cybernetic, :environment, :test)
    start_breaker!(breaker, failure_threshold: 2)

    for _ <- 1..3 do
      conn = dispatch(conn(:post, "/v1/generate"), respond_with(500))
      assert conn.status == 500
      refute conn.halted
    end

    stats = AdaptiveCircuitBreaker.get_state(breaker)
    assert stats.failure_count == 0
    assert stats.success_count == 0
    assert stats.state == :closed
  end

  # Helpers

  defp start_breaker!(breaker, opts) do
    start_supervised!({AdaptiveCircuitBreaker, [name: breaker] ++ opts})
    breaker
  end

  defp breaker_state(breaker), do: AdaptiveCircuitBreaker.get_state(breaker).state

  # Compose plug + downstream the way a Phoenix pipeline does: if the
  # plug halted the conn, downstream never runs.
  defp dispatch(conn, downstream) do
    conn = CircuitBreaker.call(conn, CircuitBreaker.init([]))
    if conn.halted, do: conn, else: downstream.(conn)
  end

  defp respond_with(status, notify \\ nil) do
    fn conn ->
      if notify, do: send(notify, :downstream_called)
      send_resp(conn, status, "downstream")
    end
  end

  defp flush_downstream_markers do
    receive do
      :downstream_called -> flush_downstream_markers()
    after
      0 -> :ok
    end
  end

  # Recording is cast-based (async), so poll the breaker's state with a
  # deadline instead of sleeping fixed durations.
  defp assert_eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("breaker condition not met within deadline")

      true ->
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:cybernetic, key)
  defp restore_env(key, value), do: Application.put_env(:cybernetic, key, value)
end
