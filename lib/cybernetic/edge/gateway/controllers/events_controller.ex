defmodule Cybernetic.Edge.Gateway.EventsController do
  @moduledoc """
  Server-Sent Events controller for streaming VSM updates.

  Supports topic-based subscriptions:
  - vsm.* - All VSM system events
  - episode.* - Episode lifecycle events
  - policy.* - Policy change events
  - artifact.* - Storage artifact events

  ## Usage

      GET /v1/events?topics=vsm.*,episode.*

  Heartbeats are sent every 30 seconds to keep connections alive.
  """
  use Phoenix.Controller
  require Logger

  @pubsub Cybernetic.PubSub
  @heartbeat_interval 30_000
  @default_topics ["vsm.*", "episode.*", "policy.*", "artifact.*"]

  @type topic :: String.t()

  @doc """
  Stream SSE events to the client.

  ## Parameters

    * `topics` - Comma-separated list of topic patterns (default: all topics)
    * `last_event_id` - Resume from this event ID (for reconnection)
  """
  @spec stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stream(conn, params) do
    topics = parse_topics(params["topics"])
    last_event_id = params["last_event_id"]

    Logger.info("SSE connection opened",
      topics: topics,
      last_event_id: last_event_id,
      client_ip: get_client_ip(conn)
    )

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Subscribe to requested topics
    subscribe_to_topics(topics)

    # Send initial connection event
    {:ok, conn} = send_event(conn, "connected", %{
      status: "connected",
      topics: topics,
      timestamp: DateTime.utc_now()
    })

    # Start the streaming loop
    stream_loop(conn, topics)
  end

  # Parse comma-separated topics or use defaults
  @spec parse_topics(String.t() | nil) :: [topic()]
  defp parse_topics(nil), do: @default_topics
  defp parse_topics(""), do: @default_topics
  defp parse_topics(topics_string) do
    topics_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&valid_topic?/1)
    |> case do
      [] -> @default_topics
      topics -> topics
    end
  end

  # Validate topic pattern
  @spec valid_topic?(String.t()) :: boolean()
  defp valid_topic?(topic) do
    String.match?(topic, ~r/^[a-z0-9_]+\.(\*|[a-z0-9_]+)$/)
  end

  # Subscribe to Phoenix PubSub topics
  @spec subscribe_to_topics([topic()]) :: :ok
  defp subscribe_to_topics(topics) do
    Enum.each(topics, fn topic ->
      # Convert pattern to actual topic name for subscription
      pubsub_topic = topic_to_pubsub(topic)
      Phoenix.PubSub.subscribe(@pubsub, pubsub_topic)
    end)
  end

  # Convert topic pattern to PubSub topic
  @spec topic_to_pubsub(String.t()) :: String.t()
  defp topic_to_pubsub(topic) do
    # For wildcard topics, subscribe to the base topic
    topic
    |> String.replace(".*", "")
    |> then(&"events:#{&1}")
  end

  # Main streaming loop with heartbeat
  @spec stream_loop(Plug.Conn.t(), [topic()]) :: Plug.Conn.t()
  defp stream_loop(conn, topics) do
    receive do
      {:event, event_type, data} ->
        case send_event(conn, event_type, data) do
          {:ok, conn} ->
            stream_loop(conn, topics)

          {:error, reason} ->
            Logger.info("SSE connection closed", reason: reason)
            conn
        end

      {:broadcast, event_type, data, _from} ->
        # Handle Phoenix.PubSub broadcasts
        case send_event(conn, event_type, data) do
          {:ok, conn} ->
            stream_loop(conn, topics)

          {:error, reason} ->
            Logger.info("SSE connection closed", reason: reason)
            conn
        end

      :close ->
        Logger.info("SSE connection closed by server")
        conn
    after
      @heartbeat_interval ->
        case send_heartbeat(conn) do
          {:ok, conn} ->
            stream_loop(conn, topics)

          {:error, reason} ->
            Logger.info("SSE connection closed on heartbeat", reason: reason)
            conn
        end
    end
  end

  # Send an SSE event
  @spec send_event(Plug.Conn.t(), String.t(), map()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  defp send_event(conn, event_type, data) do
    event_id = generate_event_id()
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    payload = Map.merge(data, %{event_id: event_id, timestamp: timestamp})
    encoded = Jason.encode!(payload)

    sse_message = """
    id: #{event_id}
    event: #{event_type}
    data: #{encoded}

    """

    chunk(conn, sse_message)
  end

  # Send a heartbeat comment
  @spec send_heartbeat(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  defp send_heartbeat(conn) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    chunk(conn, ": heartbeat #{timestamp}\n\n")
  end

  # Generate unique event ID for reconnection support
  @spec generate_event_id() :: String.t()
  defp generate_event_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower)
  end

  # Extract client IP from connection
  @spec get_client_ip(Plug.Conn.t()) :: String.t()
  defp get_client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [ip | _] -> ip
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
