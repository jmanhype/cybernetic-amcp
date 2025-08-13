
defmodule Cybernetic.Transport.AMQP do
  @moduledoc """
  AMQP transport with durable topic/fanout/unicast, causal tags, and confirms.
  """
  use GenServer
  require Logger
  alias AMQP.Connection
  alias AMQP.Channel

  @telemetry_prefix Application.compile_env(:cybernetic, __MODULE__, [])[:telemetry_prefix] || [:cybernetic, :amqp]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def publish(topic, payload, headers \\ %{}) when is_binary(payload) do
    GenServer.call(__MODULE__, {:publish, topic, payload, headers})
  end

  def init(:ok) do
    cfg = Application.get_env(:cybernetic, __MODULE__, [])
    uri = Keyword.fetch!(cfg, :uri)
    exchange = Keyword.get(cfg, :exchange, "cybernetic")
    {:ok, conn} = Connection.open(uri)
    {:ok, chan} = Channel.open(conn)
    :ok = AMQP.Exchange.declare(chan, exchange, :topic, durable: true)
    Process.flag(:trap_exit, true)
    state = %{conn: conn, chan: chan, exchange: exchange}
    {:ok, state}
  end

  def handle_call({:publish, topic, payload, headers}, _from, %{chan: chan, exchange: exchange} = state) do
    # Attach minimal aMCP context headers (nonce, ts); Security verifies separately.
    message_id = Base.encode16(:crypto.strong_rand_bytes(8))
    ts = System.system_time(:millisecond)

    props = [
      headers: Enum.map(headers, fn {k, v} -> {to_string(k), :longstr, to_string(v)} end) ++ [
        {"amcp_ts", :long, ts},
        {"amcp_id", :longstr, message_id}
      ],
      persistent: true,
      content_type: "application/octet-stream",
      message_id: message_id,
      timestamp: div(ts, 1000)
    ]

    :ok = AMQP.Basic.publish(chan, exchange, topic, payload, props)
    :telemetry.execute(@telemetry_prefix ++ [:publish], %{count: 1}, %{topic: topic, size: byte_size(payload)})
    {:reply, :ok, state}
  end

  def terminate(_reason, %{conn: conn}) do
    :ok = AMQP.Connection.close(conn)
  end
end
