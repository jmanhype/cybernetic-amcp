defmodule Cybernetic.Edge.Gateway.Plugs.CircuitBreaker do
  @moduledoc """
  Circuit breaker plug for downstream service protection.

  Production behavior:
  - If the Edge gateway circuit breaker is open, rejects requests with `503`
  - Otherwise the request proceeds and its outcome is recorded into the
    same breaker when the response is sent: a `5xx` status records a
    failure, any other status records a success. Recording is what makes
    the breaker able to trip (coupling #10): previously the plug only
    read breaker state, and nothing in the edge ever changed it.

  Recording happens in a `Plug.Conn.register_before_send/2` callback, so
  it sees the final response status — including a `500` rendered by the
  endpoint's error handling on this same conn after a downstream raise.
  A raise therefore propagates untouched and is recorded as a failure
  when the error response is sent; a request that never produces a
  response on this conn records nothing.

  Dev/test behavior:
  - Passes through (no state check, no recording)
  """
  @behaviour Plug
  import Plug.Conn
  require Logger

  @doc """
  Initialize the circuit breaker plug.
  """
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc """
  Check circuit breaker state, reject if open in production, and record
  the request outcome into the breaker when the response is sent.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    env = Application.get_env(:cybernetic, :environment, :prod)

    case env do
      env when env in [:dev, :test] ->
        # Dev/test: pass through for convenience
        conn

      :prod ->
        enforce_circuit_breaker(conn)
    end
  end

  defp enforce_circuit_breaker(conn) do
    breaker_name = breaker_name()

    try do
      # AdaptiveCircuitBreaker.get_state/1 replies with the bare stats
      # map (see its handle_call(:get_state) clause). Matching on an
      # {:ok, _} tuple here made the open check unreachable.
      case Cybernetic.Core.Resilience.AdaptiveCircuitBreaker.get_state(breaker_name) do
        %{state: :open} ->
          Logger.warning("Edge gateway circuit breaker open", breaker: breaker_name)
          reject(conn)

        %{} ->
          record_outcome_on_send(conn, breaker_name)

        other ->
          Logger.debug("Edge gateway circuit breaker state unavailable", result: inspect(other))
          conn
      end
    rescue
      # Handle specific known exceptions - avoid masking programming errors
      e in [ArgumentError, RuntimeError, ErlangError, FunctionClauseError] ->
        # P1 Security: Fail safe in production instead of failing open
        env = Application.get_env(:cybernetic, :environment, :prod)

        if env == :prod do
          Logger.error("Edge gateway circuit breaker unavailable - failing safe",
            error: inspect(e)
          )

          reject(conn)
        else
          Logger.debug("Edge gateway circuit breaker check failed", error: inspect(e))
          conn
        end
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{error: "service_unavailable", message: "Service degraded"}))
    |> halt()
  end

  defp breaker_name do
    Application.get_env(:cybernetic, :edge_gateway, [])
    |> Keyword.get(:circuit_breaker_name, :edge_gateway)
  end

  # Register a before-send callback that records the request outcome
  # into the same breaker this plug checks. Classification: a 5xx status
  # is a downstream failure; every other status (2xx/3xx/4xx) means the
  # downstream responded and counts as a success.
  defp record_outcome_on_send(conn, breaker_name) do
    register_before_send(conn, fn conn ->
      record_outcome(breaker_name, conn.status)
      conn
    end)
  end

  defp record_outcome(breaker_name, status) do
    if is_integer(status) and status >= 500 do
      Cybernetic.Core.Resilience.AdaptiveCircuitBreaker.record_failure(
        breaker_name,
        {:http_status, status}
      )
    else
      Cybernetic.Core.Resilience.AdaptiveCircuitBreaker.record_success(breaker_name)
    end
  rescue
    # Recording must never break the response path (e.g. the breaker
    # crashed between the state check and the send).
    e ->
      Logger.debug("Edge gateway circuit breaker recording failed", error: inspect(e))
      :ok
  end
end
