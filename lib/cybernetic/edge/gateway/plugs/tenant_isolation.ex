defmodule Cybernetic.Edge.Gateway.Plugs.TenantIsolation do
  @moduledoc """
  Tenant isolation plug - ensures requests are isolated by tenant.

  Production behavior:
  - Requires `conn.assigns[:tenant_id]`
  - If `x-tenant-id` header is present, it must match the authenticated tenant

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
        enforce_tenant_isolation(conn)
    end
  end

  defp enforce_tenant_isolation(conn) do
    tenant_id = conn.assigns[:tenant_id]

    cond do
      not is_binary(tenant_id) or tenant_id == "" ->
        Logger.warning("TenantIsolation: missing tenant_id assignment")
        reject(conn, 401, "unauthorized", "Missing tenant context")

      (requested_tenant = requested_tenant(conn)) && requested_tenant != tenant_id ->
        Logger.warning("TenantIsolation: tenant mismatch",
          requested_tenant: requested_tenant,
          authenticated_tenant: tenant_id
        )

        reject(conn, 403, "forbidden", "Tenant mismatch")

      true ->
        conn
    end
  end

  defp requested_tenant(conn) do
    case get_req_header(conn, "x-tenant-id") do
      [tenant] when is_binary(tenant) and tenant != "" -> tenant
      _ -> nil
    end
  end

  defp reject(conn, status, error, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error, message: message}))
    |> halt()
  end
end
