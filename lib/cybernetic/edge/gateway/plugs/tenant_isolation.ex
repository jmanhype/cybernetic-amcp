defmodule Cybernetic.Edge.Gateway.Plugs.TenantIsolation do
  @moduledoc """
  Tenant isolation plug - ensures requests are isolated by tenant.

  P0 Security: Fails closed in production - rejects all requests until implemented.
  In dev/test, passes through for convenience.
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
        # P0 Security: Production fail-closed - reject until tenant isolation is implemented
        Logger.error("TenantIsolation: Not implemented - rejecting request in production")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{
          error: "service_unavailable",
          message: "Tenant isolation not configured"
        }))
        |> halt()
    end
  end
end
