defmodule Cybernetic.Edge.Gateway.Plugs.CircuitBreaker do
  @moduledoc """
  Circuit breaker plug for downstream service protection.

  Production behavior:
  - If the Edge gateway circuit breaker is open, rejects requests with `503`

  Dev/test behavior:
  - Passes through
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

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
    breaker_name =
      Application.get_env(:cybernetic, :edge_gateway, [])
      |> Keyword.get(:circuit_breaker_name, :edge_gateway)

    try do
      case Cybernetic.Core.Resilience.AdaptiveCircuitBreaker.get_state(breaker_name) do
        {:ok, %{state: :open}} ->
          Logger.warning("Edge gateway circuit breaker open", breaker: breaker_name)
          reject(conn)

        {:ok, _} ->
          conn

        other ->
          Logger.debug("Edge gateway circuit breaker state unavailable", result: inspect(other))
          conn
      end
    rescue
      e ->
        Logger.debug("Edge gateway circuit breaker check failed", error: inspect(e))
        conn
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{error: "service_unavailable", message: "Service degraded"}))
    |> halt()
  end
end
