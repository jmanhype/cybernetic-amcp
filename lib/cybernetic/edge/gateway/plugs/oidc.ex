defmodule Cybernetic.Edge.Gateway.Plugs.OIDC do
  @moduledoc """
  Authentication plug for the Edge Gateway.

  Production behavior:
  - Requires either `Authorization: Bearer <token>` or `x-api-key: <key>`
  - Uses `Cybernetic.Security.AuthManager` for validation

  Dev/test behavior:
  - Allows unauthenticated access (assigns a default tenant)
  - Still accepts auth headers if provided
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    env = Application.get_env(:cybernetic, :environment, :prod)

    case authenticate(conn) do
      {:ok, auth_context} ->
        conn
        |> assign(:auth_context, auth_context)
        |> assign(:tenant_id, tenant_id_from_auth(auth_context))

      {:error, :missing_credentials} when env in [:dev, :test] ->
        Logger.debug("Edge auth: dev/test mode - assigning default tenant")
        assign(conn, :tenant_id, "default-tenant")

      {:error, :missing_credentials} ->
        reject(conn, 401, "unauthorized", "Missing Authorization bearer token or x-api-key")

      {:error, reason} ->
        Logger.warning("Edge auth failed", reason: inspect(reason))
        reject(conn, 401, "unauthorized", "Invalid credentials")
    end
  end

  defp authenticate(conn) do
    cond do
      bearer = bearer_token(conn) ->
        Cybernetic.Security.AuthManager.validate_token(bearer)

      api_key = api_key(conn) ->
        Cybernetic.Security.AuthManager.authenticate_api_key(api_key)

      true ->
        {:error, :missing_credentials}
    end
  rescue
    e ->
      {:error, {:exception, e}}
  end

  defp tenant_id_from_auth(%{metadata: %{tenant_id: tenant_id}}) when is_binary(tenant_id),
    do: tenant_id

  defp tenant_id_from_auth(%{user_id: user_id}) when is_binary(user_id), do: user_id
  defp tenant_id_from_auth(_), do: "unknown"

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> token
      ["bearer " <> token] when token != "" -> token
      _ -> nil
    end
  end

  defp api_key(conn) do
    case get_req_header(conn, "x-api-key") do
      [key] when is_binary(key) and key != "" -> key
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
