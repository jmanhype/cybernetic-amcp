defmodule Cybernetic.VSM.EventProducersTest do
  @moduledoc """
  Phase 2 (§6) producer bar: every telemetry event name the reflex
  arc attaches to has a real producer in lib/, driven here through
  the actual seam - no counted-but-unproduced names. The two
  consumer dispatch seams emit the work/message event set mapped
  from the dispatch outcome; the Hermes Registry emits its
  invocation event under the :cybernetic prefix; the S4 Router
  emits per-call token usage where it already computes the counts.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Core.MCP.Hermes.Registry
  alias Cybernetic.VSM.AMQPConsumer
  alias Cybernetic.VSM.System4.AMQPConsumer, as: S4Consumer
  alias Cybernetic.VSM.System4.{Episode, Router}

  defmodule StubTokensProvider do
    @moduledoc false
    def analyze_episode(_episode, _opts), do: {:ok, %{tokens: %{input: 11, output: 7}}}
  end

  defmodule StubRefusalProvider do
    @moduledoc false
    def analyze_episode(_episode, _opts),
      do: {:ok, %{tokens: %{input: 3, output: 0}, finish_reason: :content_filter}}
  end

  defmodule StubRaisingProvider do
    @moduledoc false
    def analyze_episode(_episode, _opts), do: raise("provider exploded")
  end

  @events [
    [:cybernetic, :work, :finished],
    [:cybernetic, :work, :failed],
    [:amqp, :message, :processed],
    [:amqp, :message, :error],
    [:amqp, :message, :replay],
    [:cybernetic, :mcp, :tool, :invocation],
    [:cybernetic, :s4, :usage]
  ]

  setup do
    test_pid = self()
    handler_id = "event-producers-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      @events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      %{}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # Collects the events emitted during the test, filtered to one
  # routing key so concurrent suites cannot pollute the assertions.
  defp events_for(routing_key) do
    collect([])
    |> Enum.filter(fn {_event, _meas, meta} -> meta[:routing_key] == routing_key end)
  end

  defp collect(acc) do
    receive do
      {:telemetry_event, event, meas, meta} -> collect([{event, meas, meta} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp find_event(events, name) do
    Enum.find(events, fn {event, _meas, _meta} -> event == name end)
  end

  describe "shared VSM consumer seam" do
    test "a completed dispatch emits processed + work finished, each exactly once, duration > 0" do
      key = "s1.status_update.producers"
      meta = %{routing_key: key, headers: []}

      assert :ack =
               AMQPConsumer.dispatch_with_retry(
                 :system1,
                 %{"operation" => "status_update"},
                 ~s({"operation":"status_update"}),
                 meta
               )

      events = events_for(key)

      assert {_event, %{duration: processed_ms}, _meta} =
               find_event(events, [:amqp, :message, :processed])

      assert processed_ms > 0

      assert {_event, %{duration: finished_ms}, _meta} =
               find_event(events, [:cybernetic, :work, :finished])

      assert finished_ms > 0

      assert Enum.count(events, fn {e, _, _} -> e == [:amqp, :message, :processed] end) == 1
      assert Enum.count(events, fn {e, _, _} -> e == [:cybernetic, :work, :finished] end) == 1
      refute find_event(events, [:amqp, :message, :error])
      refute find_event(events, [:amqp, :message, :replay])
      refute find_event(events, [:cybernetic, :work, :failed])
    end

    test "a poison delivery emits error + work failed, labeled :poison" do
      key = "s1.status_update.poison"
      meta = %{routing_key: key, headers: [{"_retries", :signedint, 5}]}

      assert :reject =
               AMQPConsumer.dispatch_with_retry(
                 :system1,
                 %{"operation" => "status_update"},
                 ~s({"operation":"status_update"}),
                 meta
               )

      events = events_for(key)

      assert {_event, _meas, %{reason: :poison}} = find_event(events, [:amqp, :message, :error])

      assert {_event, _meas, %{reason: :poison}} =
               find_event(events, [:cybernetic, :work, :failed])

      refute find_event(events, [:amqp, :message, :processed])
      refute find_event(events, [:cybernetic, :work, :finished])
    end

    test "a poison REDELIVERY (attempts > max) does not count the work twice (WC G3)" do
      key = "s1.status_update.poison_redelivered"
      meta = %{routing_key: key, headers: [{"_retries", :signedint, 6}]}

      assert :reject =
               AMQPConsumer.dispatch_with_retry(
                 :system1,
                 %{"operation" => "status_update"},
                 ~s({"operation":"status_update"}),
                 meta
               )

      events = events_for(key)

      # The delivery's message outcome is still reported...
      assert {_event, _meas, %{reason: :poison, attempt: 6}} =
               find_event(events, [:amqp, :message, :error])

      # ...but the unit of work is not counted a second time.
      refute find_event(events, [:cybernetic, :work, :failed])
    end
  end

  describe "System4 consumer seam" do
    test "a completed delivery emits processed + work finished with duration > 0" do
      key = "s4.reason.producers"
      meta = %{routing_key: key, headers: []}

      assert :ack =
               S4Consumer.process_delivery(
                 %{"operation" => "intelligence"},
                 ~s({"operation":"intelligence"}),
                 meta
               )

      events = events_for(key)

      assert {_event, %{duration: processed_ms}, _meta} =
               find_event(events, [:amqp, :message, :processed])

      assert processed_ms > 0

      assert {_event, %{duration: finished_ms}, _meta} =
               find_event(events, [:cybernetic, :work, :finished])

      assert finished_ms > 0
      refute find_event(events, [:cybernetic, :work, :failed])
    end

    test "a raising delivery emits replay (a retry is scheduled), not finished or failed" do
      key = "s4.reason.raising"
      meta = %{routing_key: key, headers: []}

      # A decoded JSON scalar is not a map: processing raises
      # inside process_message/3 and the bounded policy schedules
      # the retry (the IP-30 contract), settling as :ack.
      assert :ack = S4Consumer.process_delivery(123, "123", meta)

      events = events_for(key)

      assert find_event(events, [:amqp, :message, :replay])
      refute find_event(events, [:amqp, :message, :processed])
      refute find_event(events, [:cybernetic, :work, :finished])
      refute find_event(events, [:cybernetic, :work, :failed])
    end

    test "a poison delivery emits error + work failed, labeled :poison" do
      key = "s4.reason.poison"
      meta = %{routing_key: key, headers: [{"_retries", :signedint, 5}]}

      assert :reject =
               S4Consumer.process_delivery(
                 %{"operation" => "intelligence"},
                 ~s({"operation":"intelligence"}),
                 meta
               )

      events = events_for(key)

      assert {_event, _meas, %{reason: :poison}} = find_event(events, [:amqp, :message, :error])

      assert {_event, _meas, %{reason: :poison}} =
               find_event(events, [:cybernetic, :work, :failed])
    end

    test "one unit of work across raise, raise, success counts exactly once (WC G3)" do
      key = "s4.reason.unit_counting"
      raising = {123, "123"}
      ok = {%{"operation" => "intelligence"}, ~s({"operation":"intelligence"})}

      # The same unit of work, delivered three times: two raising
      # attempts (republished with _retries incremented), then a
      # completing attempt.
      assert :ack =
               S4Consumer.process_delivery(elem(raising, 0), elem(raising, 1), %{
                 routing_key: key,
                 headers: []
               })

      assert :ack =
               S4Consumer.process_delivery(elem(raising, 0), elem(raising, 1), %{
                 routing_key: key,
                 headers: [{"_retries", :signedint, 1}]
               })

      assert :ack =
               S4Consumer.process_delivery(elem(ok, 0), elem(ok, 1), %{
                 routing_key: key,
                 headers: [{"_retries", :signedint, 2}]
               })

      events = events_for(key)

      # Attempts produced message outcomes only...
      assert Enum.count(events, fn {e, _, _} -> e == [:amqp, :message, :replay] end) == 2
      assert Enum.count(events, fn {e, _, _} -> e == [:amqp, :message, :processed] end) == 1

      # ...and the unit of work was counted exactly once, on its
      # completing attempt, with the attempt number attached.
      finished = Enum.filter(events, fn {e, _, _} -> e == [:cybernetic, :work, :finished] end)
      assert [{_event, _meas, %{attempt: 2}}] = finished
      refute find_event(events, [:cybernetic, :work, :failed])
    end
  end

  describe "Hermes Registry invocation event" do
    test "invoking a tool emits [:cybernetic, :mcp, :tool, :invocation] with duration and success" do
      :ok = Registry.await_ready(2_000)

      _result = Registry.invoke_tool("vsm_query", %{system: "s3", query: "status"})

      events =
        collect([])
        |> Enum.filter(fn {_e, _m, meta} -> meta[:tool] == "vsm_query" end)

      assert {_event, %{duration: duration}, %{success: success}} =
               find_event(events, [:cybernetic, :mcp, :tool, :invocation])

      assert is_integer(duration)
      assert is_boolean(success)
    end
  end

  describe "S4 Router usage event" do
    test "a completed provider call emits [:cybernetic, :s4, :usage] with its token counts" do
      episode = %Episode{id: "ep-usage-producers", kind: :classification, priority: :normal}

      # try_provider/5 takes the provider module explicitly; the
      # provider atom must be a known config key (:ollama), while
      # the stub module supplies the token-carrying result.
      assert {:ok, %{tokens: %{input: 11, output: 7}}} =
               Router.try_provider(episode, StubTokensProvider, :ollama, [], 0)

      events =
        collect([])
        |> Enum.filter(fn {_e, _m, meta} -> meta[:provider] == :ollama end)

      assert {_event, %{tokens_in: 11, tokens_out: 7}, %{status: :success}} =
               find_event(events, [:cybernetic, :s4, :usage])
    end

    test "a refusal's finish_reason rides the usage event, not erased to a stop (WC G3)" do
      episode = %Episode{id: "ep-usage-refusal", kind: :classification, priority: :normal}

      assert {:ok, %{finish_reason: :content_filter}} =
               Router.try_provider(episode, StubRefusalProvider, :ollama, [], 0)

      events =
        collect([])
        |> Enum.filter(fn {_e, _m, meta} -> meta[:provider] == :ollama end)

      assert {_event, %{tokens_in: 3, tokens_out: 0}, %{finish_reason: :content_filter}} =
               find_event(events, [:cybernetic, :s4, :usage])
    end

    test "an error-path provider call still emits usage - zeros, status :error (WC G3)" do
      episode = %Episode{id: "ep-usage-error", kind: :classification, priority: :normal}

      assert {:error, :request_failed} =
               Router.try_provider(episode, StubRaisingProvider, :ollama, [], 0)

      events =
        collect([])
        |> Enum.filter(fn {_e, _m, meta} -> meta[:provider] == :ollama end)

      assert {_event, %{tokens_in: 0, tokens_out: 0}, %{status: :error}} =
               find_event(events, [:cybernetic, :s4, :usage])
    end
  end
end
