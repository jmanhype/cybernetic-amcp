defmodule Cybernetic.Transport.AMQP.CausalityTest do
  @moduledoc """
  IP-31 special-bar tests: Lamport stamps replace the wall-clock
  pretense, merges advance the local clock, and an out-of-order
  delivery is detected at the consume choke point and lands in the
  audit log as a causality_violation event - while processing
  continues.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Audit.Log
  alias Cybernetic.Transport.AMQP.{Causality, LamportClock}
  alias Cybernetic.VSM.AMQPConsumer

  setup do
    dir = Path.join(System.tmp_dir!(), "causality-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    clock_pid = start_if_needed(LamportClock)
    log_pid = start_if_needed(Log, dir: dir)

    on_exit(fn ->
      for pid <- [clock_pid, log_pid] do
        if pid && Process.alive?(pid), do: GenServer.stop(pid)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp start_if_needed(Log, opts) do
    case Process.whereis(Log) do
      nil ->
        {:ok, pid} = Log.start_link(opts)
        pid

      _pid ->
        nil
    end
  end

  defp start_if_needed(module, _opts \\ []) do
    case Process.whereis(module) do
      nil ->
        {:ok, pid} = module.start_link([])
        pid

      _pid ->
        nil
    end
  end

  describe "LamportClock" do
    test "tick is strictly increasing" do
      values = for _ <- 1..5, do: LamportClock.tick()
      assert values == Enum.sort(values)
      assert length(Enum.uniq(values)) == 5
    end

    test "merge advances the local clock past the received value" do
      before = LamportClock.now()
      merged = LamportClock.merge(before + 1_000)
      assert merged == before + 1_000
      assert LamportClock.tick() > merged
    end

    test "observe flags a regression against the last value seen from a node" do
      node = "observe-test-node-#{System.unique_integer([:positive])}"
      assert :ok = LamportClock.observe(node, 10)
      assert :ok = LamportClock.observe(node, 11)

      assert {:violation, %{node: ^node, expected_after: 11, received: 4}} =
               LamportClock.observe(node, 4)
    end
  end

  describe "Causality.put_headers/2" do
    test "stamps typed x-lamport / x-node headers and no opaque clock blob" do
      headers = Causality.put_headers([], "node-x")
      assert {"x-node", :longstr, "node-x"} in headers
      assert {"x-lamport", :signedint, tick} = List.keyfind(headers, "x-lamport", 0)
      assert is_integer(tick)
      refute Enum.any?(headers, fn {key, _type, _value} -> key == "x-clock" end)

      headers2 = Causality.put_headers([], "node-x")
      assert {"x-lamport", :signedint, tick2} = List.keyfind(headers2, "x-lamport", 0)
      assert tick2 > tick
    end
  end

  describe "consumer-level violation detection (the special bar)" do
    test "an out-of-order delivery lands as a causality_violation audit event", %{dir: _dir} do
      node = "causality-probe-#{System.unique_integer([:positive])}"

      deliver = fn lamport ->
        meta = %{
          routing_key: "s1.status_update",
          headers: [{"x-lamport", :signedint, lamport}, {"x-node", :longstr, node}]
        }

        AMQPConsumer.dispatch_with_retry(
          :system1,
          %{"operation" => "status_update"},
          ~s({"operation":"status_update"}),
          meta
        )
      end

      # In-order deliveries: no violations, processing acks.
      assert :ack = deliver.(10)
      assert :ack = deliver.(11)
      assert causality_violations() == []

      # Out-of-order: detected, recorded - and still acked
      # (evidence, not a gate).
      assert :ack = deliver.(5)

      violations = causality_violations()
      assert length(violations) == 1

      violation = hd(violations)
      assert violation["payload"]["node"] == node
      assert violation["payload"]["expected_after"] == 11
      assert violation["payload"]["received"] == 5

      # Back in order: no further violations.
      assert :ack = deliver.(12)
      assert length(causality_violations()) == 1
    end

    test "unstamped traffic is not a violation" do
      assert :ok = Causality.check_and_record(%{})
      assert :ok = Causality.check_and_record(%{"_routing_key" => "s1.status_update"})
      assert causality_violations() == []
    end
  end

  defp causality_violations do
    Log.entries_between()
    |> Enum.filter(&(&1["type"] == "causality_violation"))
  end
end
