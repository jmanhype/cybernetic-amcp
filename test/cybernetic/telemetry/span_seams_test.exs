defmodule Cybernetic.Telemetry.SpanSeamsTest do
  @moduledoc """
  IP-35 special-bar tests: spans must actually be emitted at the
  named seams through the existing Cybernetic.Telemetry.OTEL.

  The test env configures the OTel SDK with `traces_exporter:
  :none`, so this module temporarily reconfigures the SDK with a
  simple processor exporting to a collector process, restarts the
  :opentelemetry application, and restores the stock config on
  exit. Evidence captured: an `amqp.publish` span whose injected
  context parents the consumer's `amqp.consume` span, with
  `vsm.dispatch` as its child; an `amqp.retry` span EVENT on a
  retry; and the pre-existing `s4.route` span at the Router seam.
  """
  use ExUnit.Case, async: false

  require Record

  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias Cybernetic.Core.Transport.RetryHelper
  alias Cybernetic.Telemetry.OTEL
  alias Cybernetic.VSM.AMQPConsumer
  alias Cybernetic.VSM.System4.{Episode, Router}

  defmodule Collector do
    @moduledoc false
    use GenServer

    def start_link(_arg), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
    def spans, do: GenServer.call(__MODULE__, :spans)
    def clear, do: GenServer.call(__MODULE__, :clear)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:spans, _from, state), do: {:reply, Enum.reverse(state), state}
    def handle_call(:clear, _from, _state), do: {:reply, :ok, []}

    @impl true
    def handle_info({:span, span}, state), do: {:noreply, [span | state]}
    def handle_info(_other, state), do: {:noreply, state}
  end

  setup_all do
    {:ok, collector} = Collector.start_link([])

    # Both knobs are needed: the SDK merges the top-level
    # traces_exporter into each processor's config, so the stock
    # :none would override a processor-level exporter on its own.
    Application.put_env(:opentelemetry, :traces_exporter, {:otel_exporter_pid, collector})

    Application.put_env(:opentelemetry, :processors, [
      {:otel_batch_processor, %{scheduled_delay_ms: 50}}
    ])

    restart_opentelemetry()

    on_exit(fn ->
      Application.put_env(:opentelemetry, :traces_exporter, :none)
      Application.delete_env(:opentelemetry, :processors)
      restart_opentelemetry()
      if Process.alive?(collector), do: GenServer.stop(collector)
    end)

    :ok
  end

  setup do
    Collector.clear()
    :ok
  end

  defp restart_opentelemetry do
    case Application.stop(:opentelemetry) do
      :ok -> :ok
      {:error, _} -> :ok
    end

    {:ok, _apps} = Application.ensure_all_started(:opentelemetry)
    :ok
  end

  test "publish context parents the consume span; dispatch is its child" do
    publish_headers =
      OTEL.with_span(
        "amqp.publish",
        %{exchange: "cyb.commands", routing_key: "s1.status_update"},
        fn -> OTEL.inject_context([]) end
      )

    assert Enum.any?(publish_headers, fn {key, _type, _value} ->
             to_string(key) == "traceparent"
           end)

    [publish_span] = wait_for_spans("amqp.publish", 1)

    meta = %{routing_key: "s1.status_update", headers: publish_headers}

    assert :ack =
             AMQPConsumer.dispatch_with_retry(
               :system1,
               %{"operation" => "status_update"},
               ~s({"operation":"status_update"}),
               meta
             )

    [consume_span] = wait_for_spans("amqp.consume", 1)
    [dispatch_span] = wait_for_spans("vsm.dispatch", 1)

    assert span(consume_span, :trace_id) == span(publish_span, :trace_id)
    assert span(consume_span, :parent_span_id) == span(publish_span, :span_id)
    assert span(dispatch_span, :trace_id) == span(publish_span, :trace_id)
    assert span(dispatch_span, :parent_span_id) == span(consume_span, :span_id)

    dispatch_attrs = attrs_map(span(dispatch_span, :attributes))
    assert Map.get(dispatch_attrs, :system) == :system1
    assert Map.get(dispatch_attrs, :routing_key) == "s1.status_update"
  end

  test "a retry is an amqp.retry event on the current span, not a root span" do
    result =
      OTEL.with_span("amqp.consume", %{routing_key: "s1.status_update"}, fn ->
        RetryHelper.with_retry(%{"_retries" => 0}, "payload", fn -> {:error, :boom} end, [])
      end)

    assert result == {:error, :boom}

    [consume_span] = wait_for_spans("amqp.consume", 1)
    assert "amqp.retry" in collect_strings(span(consume_span, :events))
  end

  test "the s4.route span is emitted at the Router seam" do
    episode = Episode.new(:policy_review, "Span Probe", %{})

    # An empty override chain fails fast without touching a
    # provider; the span is the evidence being gathered here.
    assert {:error, :all_providers_failed} = Router.route(episode, override_chain: [])

    [route_span] = wait_for_spans("s4.route", 1)
    route_attrs = attrs_map(span(route_span, :attributes))
    assert Map.get(route_attrs, :episode_kind) == :policy_review
  end

  # ========== helpers ==========

  defp wait_for_spans(name, count, attempts \\ 100) do
    spans =
      Collector.spans()
      |> Enum.filter(&(span(&1, :name) == name))

    cond do
      length(spans) >= count ->
        Enum.take(spans, count)

      attempts <= 0 ->
        flunk("expected #{count} span(s) named #{name}, got: #{inspect(Collector.spans())}")

      true ->
        Process.sleep(20)
        wait_for_spans(name, count, attempts - 1)
    end
  end

  # The exported span record carries attributes in an
  # :otel_attributes tuple whose map element holds the values.
  defp attrs_map(attrs) when is_map(attrs), do: attrs

  defp attrs_map(attrs) when is_tuple(attrs) do
    attrs |> Tuple.to_list() |> Enum.find(&is_map/1) || %{}
  end

  defp attrs_map(_other), do: %{}

  defp collect_strings(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.flat_map(&collect_strings/1)
  end

  defp collect_strings(term) when is_list(term), do: Enum.flat_map(term, &collect_strings/1)
  defp collect_strings(term) when is_binary(term), do: [term]
  defp collect_strings(_term), do: []
end
