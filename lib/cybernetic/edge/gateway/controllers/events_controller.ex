defmodule Cybernetic.Edge.Gateway.EventsController do
  @moduledoc """
  Server-Sent Events controller for streaming updates.
  """
  use Phoenix.Controller
  require Logger

  def stream(conn, _params) do
    conn = conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)

    # Send initial connection event
    {:ok, conn} = chunk(conn, "event: connected\ndata: {\"status\":\"connected\"}\n\n")

    # Keep connection open - in production this would subscribe to a PubSub
    # For now, just hold the connection
    receive do
      {:event, data} ->
        chunk(conn, "event: message\ndata: #{Jason.encode!(data)}\n\n")
    after
      30_000 ->
        # Send heartbeat every 30s
        chunk(conn, "event: heartbeat\ndata: {\"timestamp\":\"#{DateTime.utc_now() |> DateTime.to_iso8601()}\"}\n\n")
    end

    conn
  end
end
