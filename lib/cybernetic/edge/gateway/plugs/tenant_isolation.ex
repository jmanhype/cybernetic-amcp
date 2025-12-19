defmodule Cybernetic.Edge.Gateway.Plugs.TenantIsolation do
  @moduledoc """
  Tenant isolation plug - ensures requests are isolated by tenant.

  Production behavior:
  - Requires `conn.assigns[:tenant_id]`
  - If `x-tenant-id` header is present, it must match the authenticated tenant

  Dev/test behavior:
  - Passes through
  """
  @behaviour Plug
  import Plug.Conn
  require Logger

  @doc """
  Initialize the tenant isolation plug.
  """
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc """
  Enforce tenant isolation in production.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
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

  # P2 Security: Validate tenant ID format to prevent injection
  @tenant_id_max_length 128
  @tenant_id_pattern ~r/^[a-zA-Z0-9_-]+$/

  defp requested_tenant(conn) do
    case get_req_header(conn, "x-tenant-id") do
      [tenant] when is_binary(tenant) and tenant != "" ->
        if valid_tenant_id?(tenant) do
          tenant
        else
          Logger.warning("TenantIsolation: invalid tenant ID format in header", 
            tenant_preview: String.slice(tenant, 0, 20))
          nil
        end
      _ -> 
        nil
    end
  end

  @spec valid_tenant_id?(String.t()) :: boolean()
  defp valid_tenant_id?(tenant_id) do
    byte_size(tenant_id) <= @tenant_id_max_length and
      Regex.match?(@tenant_id_pattern, tenant_id)
  end

  defp reject(conn, status, error, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error, message: message}))
    |> halt()
  end
end
