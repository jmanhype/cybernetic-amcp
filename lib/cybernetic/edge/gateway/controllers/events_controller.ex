defmodule Cybernetic.Edge.Gateway.EventsController do
  @moduledoc """
  Server-Sent Events (SSE) controller for streaming real-time updates
  to authenticated clients. Supports tenant-isolated event streams.
  """
  use Phoenix.Controller
  require Logger

  @doc """
  Handle GET /v1/events for SSE streaming
  """
  def stream(conn, _params) do
    with {:ok, tenant_id} <- get_tenant_id(conn) do
      # Set SSE headers
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(:ok)

      # Subscribe to tenant-specific events
      topic = "events:tenant:#{tenant_id}"
      Phoenix.PubSub.subscribe(Cybernetic.PubSub, topic)

      # Send initial connection event
      request_id = get_request_id(conn)

      initial_event =
        format_sse_event("connected", %{
          tenant_id: tenant_id,
          request_id: request_id,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:ok, conn} = chunk(conn, initial_event)

      # Emit telemetry
      :telemetry.execute(
        [:cybernetic, :edge, :sse, :connected],
        %{count: 1},
        %{tenant_id: tenant_id}
      )

      # Keep connection alive and stream events
      stream_loop(conn, tenant_id, request_id)
    else
      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Unauthorized", code: "AUTH_REQUIRED"})
    end
  end

  # Private Functions

  defp get_tenant_id(conn) do
    case conn.assigns[:tenant_id] do
      nil -> {:error, :unauthorized}
      tenant_id -> {:ok, tenant_id}
    end
  end

  defp get_request_id(conn) do
    conn.assigns[:request_id] || generate_uuid()
  end

  defp generate_uuid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> String.slice(0..31)
  end

  defp stream_loop(conn, tenant_id, request_id) do
    receive do
      # Handle pubsub events
      %{event: event_type, payload: payload} ->
        sse_event = format_sse_event(event_type, payload)

        case chunk(conn, sse_event) do
          {:ok, conn} ->
            stream_loop(conn, tenant_id, request_id)

          {:error, _reason} ->
            # Client disconnected
            cleanup_stream(tenant_id, request_id)
            conn
        end

      # Keepalive ping every 30 seconds
      :keepalive ->
        ping_event = format_sse_event("ping", %{timestamp: DateTime.utc_now() |> DateTime.to_iso8601()})

        case chunk(conn, ping_event) do
          {:ok, conn} ->
            Process.send_after(self(), :keepalive, 30_000)
            stream_loop(conn, tenant_id, request_id)

          {:error, _reason} ->
            cleanup_stream(tenant_id, request_id)
            conn
        end

      # Graceful shutdown
      {:shutdown, reason} ->
        Logger.info("SSE stream shutdown: #{inspect(reason)}")
        cleanup_stream(tenant_id, request_id)
        conn
    after
      # Initial keepalive schedule
      30_000 ->
        Process.send_after(self(), :keepalive, 30_000)
        stream_loop(conn, tenant_id, request_id)
    end
  end

  defp cleanup_stream(tenant_id, request_id) do
    # Unsubscribe from events
    topic = "events:tenant:#{tenant_id}"
    Phoenix.PubSub.unsubscribe(Cybernetic.PubSub, topic)

    # Emit telemetry
    :telemetry.execute(
      [:cybernetic, :edge, :sse, :disconnected],
      %{count: 1},
      %{tenant_id: tenant_id, request_id: request_id}
    )

    Logger.debug("SSE stream closed for tenant #{tenant_id}")
  end

  defp format_sse_event(event_type, data) do
    json_data = Jason.encode!(data)
    "event: #{event_type}\ndata: #{json_data}\n\n"
  end
end
