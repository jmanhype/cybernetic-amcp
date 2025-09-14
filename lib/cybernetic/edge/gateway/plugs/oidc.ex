defmodule Cybernetic.Edge.Gateway.Plugs.OIDC do
  @moduledoc """
  OIDC authentication plug - placeholder for now
  """
  import Plug.Conn
  
  def init(opts), do: opts
  
  def call(conn, _opts) do
    # TODO: Implement OIDC authentication
    # For now, just assign a default tenant_id for development
    assign(conn, :tenant_id, "default-tenant")
  end
end