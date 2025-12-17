defmodule Cybernetic.Edge.Gateway.MetricsController do
  @moduledoc """
  Prometheus metrics endpoint controller.
  """
  use Phoenix.Controller

  def index(conn, _params) do
    # TODO: Integrate with Prometheus/Telemetry metrics
    metrics = """
    # HELP cybernetic_requests_total Total number of requests
    # TYPE cybernetic_requests_total counter
    cybernetic_requests_total 0
    # HELP cybernetic_up Service status
    # TYPE cybernetic_up gauge
    cybernetic_up 1
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end
end
