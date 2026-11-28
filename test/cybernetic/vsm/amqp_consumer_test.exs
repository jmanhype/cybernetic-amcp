defmodule Cybernetic.VSM.AMQPConsumerTest do
  @moduledoc """
  Coupling #6 (stage 2): dispatch-level tests for the shared VSM
  queue consumer, `Cybernetic.VSM.AMQPConsumer`.

  No broker exists in this environment, so these tests exercise
  `dispatch/4` - the function the consumer's delivery handler
  calls after JSON-decoding a delivery - and prove each canonical
  queue's messages reach the owning system's real entry point:
  System1/System2/System5 `MessageHandler.handle_message/3` and
  System3's `ControlSupervisor.process_vsm_message/2`.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Transport.InMemory
  alias Cybernetic.VSM.AMQPConsumer
  alias Cybernetic.VSM.System3.ControlSupervisor

  describe "child_spec/1" do
    test "derives a unique child id from the :name option for each queue instance" do
      instances = [
        {"cyb.s1.ops", :system1, Cybernetic.VSM.AMQPConsumer.S1},
        {"cyb.s2.coord", :system2, Cybernetic.VSM.AMQPConsumer.S2},
        {"cyb.s3.control", :system3, Cybernetic.VSM.AMQPConsumer.S3},
        {"cyb.s5.policy", :system5, Cybernetic.VSM.AMQPConsumer.S5}
      ]

      specs =
        Enum.map(instances, fn {queue, system, name} ->
          AMQPConsumer.child_spec(queue: queue, system: system, name: name)
        end)

      assert Enum.map(specs, & &1.id) == Enum.map(instances, &elem(&1, 2))

      assert Enum.all?(specs, fn spec ->
               match?({AMQPConsumer, :start_link, [_opts]}, spec.start)
             end)
    end
  end

  describe "dispatch/4 to System1" do
    test "reaches System1's message handler" do
      assert :ok =
               AMQPConsumer.dispatch(
                 :system1,
                 %{"operation" => "status_update"},
                 "s1.status_update",
                 %{}
               )

      assert :ok =
               AMQPConsumer.dispatch(
                 :system1,
                 %{"operation" => "telemetry"},
                 "s1.telemetry",
                 %{}
               )
    end

    test "the s1.coordination routing key maps to the coordination operation" do
      assert :ok =
               AMQPConsumer.dispatch(
                 :system1,
                 %{"action" => "start", "task_id" => "t1"},
                 "s1.coordination",
                 %{}
               )
    end

    test "unknown operations are rejected by the handler" do
      assert {:error, :unknown_operation} =
               AMQPConsumer.dispatch(:system1, %{"operation" => "bogus"}, "s1.bogus", %{})
    end
  end

  describe "dispatch/4 to System2" do
    setup do
      InMemory.set_test_collector(self())
      on_exit(fn -> InMemory.set_test_collector(nil) end)
      :ok
    end

    test "a coordination message reaches System2's handler and forwards intelligence to S4" do
      # The shape System1's handler publishes on s2.coordinate.
      message = %{
        "type" => "vsm.s2.coordinate",
        "source_system" => "s1",
        "operation" => "operation",
        "coordination_id" => "coord_dispatch_test",
        "original_payload" => %{"operation" => "operation"}
      }

      assert :ok = AMQPConsumer.dispatch(:system2, message, "s2.coordinate", %{})

      # System2's coordinate handling forwards an intelligence
      # signal to S4; under the InMemory test transport that
      # delivery is observable at the test collector, which proves
      # the S2 handler actually ran.
      assert_receive {:system4_message, %{"type" => "vsm.s4.intelligence"}}, 500
    end

    test "unknown operations are rejected by the handler" do
      assert {:error, :unknown_operation} =
               AMQPConsumer.dispatch(:system2, %{"operation" => "bogus"}, "s2.bogus", %{})
    end
  end

  describe "dispatch/4 to System3" do
    setup do
      {:ok, control_supervisor: fresh_control_supervisor()}
    end

    # The suite shares the named ControlSupervisor: neighboring
    # modules start it linked to their own test processes, so an
    # already-registered pid may be mid-teardown when this setup
    # runs (its owner test process exited). Stop any existing
    # instance and start a fresh one - the pattern
    # ControlSupervisorHealthTest already uses.
    defp fresh_control_supervisor do
      if pid = Process.whereis(ControlSupervisor) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end

      {:ok, pid} = ControlSupervisor.start_link()
      pid
    end

    test "an algedonic AMQP payload lands in ControlSupervisor's algedonic machinery" do
      before = ControlSupervisor.get_status()

      payload = %{
        "type" => "algedonic.pain",
        "severity" => "severe",
        "metrics" => %{"success" => 1, "failure" => 9}
      }

      assert :ok =
               AMQPConsumer.dispatch(:system3, payload, "s3.algedonic.pain.severe", %{})

      Process.sleep(100)
      status = ControlSupervisor.get_status()
      assert status.active_interventions > before.active_interventions

      assert Enum.any?(status.recent_algedonic, fn signal ->
               signal.type == :pain and signal.intensity == 0.85 and
                 signal.source == :goldrush_telemetry
             end)
    end

    test "unknown S3 payloads return an honest error" do
      assert {:error, :unknown_message_type} =
               AMQPConsumer.dispatch(:system3, %{"type" => "nope"}, "s3.nope", %{})
    end
  end

  describe "dispatch/4 to System5" do
    test "reaches System5's message handler" do
      assert :ok =
               AMQPConsumer.dispatch(
                 :system5,
                 %{"operation" => "identity_check"},
                 "s5.identity",
                 %{}
               )

      assert :ok =
               AMQPConsumer.dispatch(
                 :system5,
                 %{"operation" => "policy_update"},
                 "s5.policy",
                 %{}
               )
    end

    test "unknown operations are rejected by the handler" do
      assert {:error, :unknown_operation} =
               AMQPConsumer.dispatch(:system5, %{"operation" => "bogus"}, "s5.bogus", %{})
    end
  end

  test "non-map messages are rejected without reaching a handler" do
    assert {:error, :invalid_message} =
             AMQPConsumer.dispatch(:system1, "garbage", "s1.telemetry", %{})

    assert {:error, :invalid_message} =
             AMQPConsumer.dispatch(:system3, ["not", "a", "map"], "s3.control", %{})
  end

  describe "dispatch_with_retry/5 (IP-30 bounded retry)" do
    test "a successful dispatch settles as :ack" do
      meta = %{routing_key: "s1.status_update", headers: []}

      assert :ack =
               AMQPConsumer.dispatch_with_retry(
                 :system1,
                 %{"operation" => "status_update"},
                 ~s({"operation":"status_update"}),
                 meta
               )
    end

    test "a handler contract error is an outcome, not a delivery failure: :ack, no retry" do
      meta = %{routing_key: "s1.bogus", headers: []}

      assert :ack =
               AMQPConsumer.dispatch_with_retry(
                 :system1,
                 %{"operation" => "bogus"},
                 ~s({"operation":"bogus"}),
                 meta
               )
    end

    test "a delivery whose retry count is exhausted settles as :reject without dispatching" do
      # _retries at the RetryHelper cap (5): the message is poison,
      # so even a payload that would dispatch successfully is
      # rejected for dead-lettering.
      meta = %{routing_key: "s1.status_update", headers: [{"_retries", :signedint, 5}]}

      assert :reject =
               AMQPConsumer.dispatch_with_retry(
                 :system1,
                 %{"operation" => "status_update"},
                 ~s({"operation":"status_update"}),
                 meta
               )
    end
  end
end
