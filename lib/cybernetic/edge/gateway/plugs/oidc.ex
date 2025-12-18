defmodule Cybernetic.Edge.Gateway.Plugs.OIDC do
  @moduledoc """
  OIDC authentication plug.

  P0 Security: Fails closed in production - rejects all requests until implemented.
  In dev/test, assigns a default tenant for convenience.
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    env = Application.get_env(:cybernetic, :environment, :prod)

    case env do
      env when env in [:dev, :test] ->
        # Dev/test: assign default tenant for convenience
        Logger.debug("OIDC: Dev/test mode - assigning default tenant")
        assign(conn, :tenant_id, "default-tenant")

      :prod ->
        # P0 Security: Production fail-closed - reject until OIDC is implemented
        Logger.error("OIDC: Authentication not implemented - rejecting request in production")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{
          error: "service_unavailable",
          message: "Authentication service not configured"
        }))
        |> halt()
    end
  end
end
