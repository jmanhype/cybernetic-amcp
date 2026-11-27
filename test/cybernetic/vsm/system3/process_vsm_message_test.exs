defmodule Cybernetic.VSM.System3.ProcessVsmMessageTest do
  @moduledoc """
  Coupling #6 (stage 2): `ControlSupervisor.process_vsm_message/2`
  is the dispatch the `cyb.s3.control` queue consumer delivers
  into. Algedonic payloads must land in the algedonic machinery
  (buffer, thresholds, intervention) through the existing
  `report_algedonic/3` path, policy updates must reach the policy
  cache handler, and unknown types must be rejected honestly -
  the previous implementation was a no-op catch-all that silently
  swallowed every message.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.VSM.System3.ControlSupervisor

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

  test "Goldrush-shaped severe pain payload is buffered and opens an intervention" do
    before = ControlSupervisor.get_status()

    # The shape the Goldrush TelemetryAlgedonic plugin publishes
    # over AMQP (JSON-decoded): atom keys/values become strings,
    # and there is no source field - the metrics map is its mark.
    payload = %{
      "type" => "algedonic.pain",
      "severity" => "severe",
      "success_rate" => 0.15,
      "avg_latency" => 120.0,
      "metrics" => %{"success" => 15, "failure" => 85},
      "timestamp" => "2026-11-27T00:00:00Z"
    }

    assert :ok =
             ControlSupervisor.process_vsm_message(payload, "s3.algedonic.pain.severe")

    Process.sleep(100)
    status = ControlSupervisor.get_status()
    assert status.control_state == :critical
    assert status.active_interventions > before.active_interventions

    assert Enum.any?(status.recent_algedonic, fn signal ->
             signal.type == :pain and signal.intensity == 0.85 and
               signal.source == :goldrush_telemetry
           end)
  end

  test "S1-shaped algedonic payload takes source and level from the payload" do
    payload = %{
      "operation" => "algedonic",
      "type" => "algedonic.pleasure",
      "source_system" => "s1",
      "data" => %{"intensity" => "high"}
    }

    assert :ok =
             ControlSupervisor.process_vsm_message(payload, "s3.algedonic.pleasure.high")

    Process.sleep(100)
    status = ControlSupervisor.get_status()

    assert Enum.any?(status.recent_algedonic, fn signal ->
             signal.type == :pleasure and signal.intensity == 0.85 and signal.source == :s1
           end)
  end

  test "the routing key alone identifies an algedonic payload and its level" do
    assert :ok =
             ControlSupervisor.process_vsm_message(
               %{"severity" => "critical"},
               "s3.algedonic.pain.critical"
             )

    Process.sleep(100)
    status = ControlSupervisor.get_status()

    assert Enum.any?(status.recent_algedonic, fn signal ->
             signal.type == :pain and signal.intensity == 0.95
           end)
  end

  test "an explicit numeric intensity is used as-is" do
    assert :ok =
             ControlSupervisor.process_vsm_message(
               %{"type" => "algedonic.pain", "intensity" => 0.3, "source_system" => "s2"},
               "s3.algedonic.pain"
             )

    Process.sleep(100)
    status = ControlSupervisor.get_status()

    assert Enum.any?(status.recent_algedonic, fn signal ->
             signal.type == :pain and signal.intensity == 0.3 and signal.source == :s2
           end)
  end

  test "policy update payloads reach the policy cache handler" do
    assert :ok =
             ControlSupervisor.process_vsm_message(
               %{
                 "type" => "policy_update",
                 "policy_id" => "amqp_test_policy",
                 "policy" => %{"type" => "resource_limit", "rules" => %{"max_cpu" => 0.9}}
               },
               "s3.policy"
             )
  end

  test "a policy update missing its id or data is rejected" do
    assert {:error, :invalid_policy_update} =
             ControlSupervisor.process_vsm_message(%{"type" => "policy_update"}, "s3.policy")
  end

  test "unknown message types are rejected, not silently swallowed" do
    assert {:error, :unknown_message_type} =
             ControlSupervisor.process_vsm_message(
               %{"type" => "something.else", "data" => %{}},
               "s3.unknown"
             )

    assert {:error, :unknown_message_type} =
             ControlSupervisor.process_vsm_message(%{}, "s3.control")

    assert {:error, :unknown_message_type} =
             ControlSupervisor.process_vsm_message("not a map", "s3.control")
  end
end
