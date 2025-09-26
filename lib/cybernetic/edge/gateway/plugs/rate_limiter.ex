defmodule Cybernetic.Edge.Gateway.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting plug using S3 RateLimiter
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    tenant_id = conn.assigns[:tenant_id] || "default"

    case Cybernetic.VSM.System3.RateLimiter.request_tokens(:api_gateway, tenant_id, :normal) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        Logger.warning("Rate limit exceeded for tenant: #{tenant_id}")

        conn
        |> put_resp_header("retry-after", "60")
        |> send_resp(429, Jason.encode!(%{error: "Rate limit exceeded"}))
        |> halt()
    end
  rescue
    _ ->
      # If rate limiter is not available, allow the request
      conn
  end
end
