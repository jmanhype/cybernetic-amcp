defmodule Cybernetic.Edge.Gateway.HealthController do
  @moduledoc """
  Health check controller for the root endpoint.
  """
  use Phoenix.Controller

  def index(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{
      status: "ok",
      service: "cybernetic-amcp",
      version: Application.spec(:cybernetic, :vsn) |> to_string(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
