defmodule Cybernetic.Edge.Gateway.MetricsController do
  @moduledoc """
  Prometheus metrics endpoint for exposing system metrics.
  Provides real-time telemetry data in Prometheus format.
  """
  use Phoenix.Controller
  require Logger

  @doc """
  Handle GET /metrics
  Returns Prometheus-formatted metrics
  """
  def index(conn, _params) do
    # TelemetryMetricsPrometheus.Core automatically exposes metrics
    # We just need to proxy the request to the metrics endpoint
    case fetch_prometheus_metrics() do
      {:ok, metrics_text} ->
        conn
        |> put_resp_content_type("text/plain; version=0.0.4")
        |> send_resp(:ok, metrics_text)

      {:error, reason} ->
        Logger.error("Failed to fetch Prometheus metrics: #{inspect(reason)}")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(:internal_server_error, "# Error fetching metrics\n")
    end
  end

  # Private Functions

  defp fetch_prometheus_metrics do
    # The Prometheus exporter is running on a separate port
    # We fetch the metrics from it
    port = Application.get_env(:telemetry_metrics_prometheus_core, :port, 9568)

    try do
      # Use TelemetryMetricsPrometheus.Core to get metrics directly
      metrics = TelemetryMetricsPrometheus.Core.scrape()
      {:ok, metrics}
    rescue
      error ->
        Logger.error("Error fetching metrics: #{inspect(error)}")

        # If direct scrape fails, try HTTP request to the metrics port
        case fetch_via_http(port) do
          {:ok, body} -> {:ok, body}
          error -> error
        end
    end
  end

  defp fetch_via_http(port) do
    url = "http://localhost:#{port}/metrics"

    case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, List.to_string(body)}

      {:ok, {{_, status_code, _}, _, _}} ->
        {:error, {:http_error, status_code}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
