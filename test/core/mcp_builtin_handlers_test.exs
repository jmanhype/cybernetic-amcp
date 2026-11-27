defmodule Cybernetic.Core.MCP.BuiltinHandlersTest do
  @moduledoc """
  The four repaired Hermes builtin tools (Issue #86 follow-up).

  `vsm_query`, `crdt_query`, `telemetry_emit`, and `send_telegram`
  were registered against handler targets that did not exist, so
  every invocation failed with an undefined-function error. Each
  test here goes through the real `Registry.invoke_tool/3` path —
  no handler is called directly.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Core.CRDT.Graph
  alias Cybernetic.Core.MCP.Hermes.Registry
  alias Cybernetic.VSM.System1.Agents.TelegramAgent
  alias Cybernetic.VSM.System3.ControlSupervisor

  @probe_event [:cybernetic, :mcp, :builtin_probe]

  setup do
    start_registry()
    :ok
  end

  # --- vsm_query ---------------------------------------------------

  test "vsm_query returns the real S3 status while ControlSupervisor runs" do
    fresh_control_supervisor()

    assert {:ok, status} =
             Registry.invoke_tool("vsm_query", %{system: "s3", query: "status"})

    assert status.system == :system3
    # The answer is ControlSupervisor's own status surface, not a
    # fabricated map.
    assert status.control_state == ControlSupervisor.get_status().control_state
    assert is_integer(status.active_interventions)
    assert is_map(status.metrics)
  end

  test "vsm_query reports a down system honestly instead of fabricating state" do
    # System1.Operational is not running in the minimal test tree.
    assert {:ok, status} =
             Registry.invoke_tool("vsm_query", %{system: "s1", query: "status"})

    assert status.system == :system1
    assert status.running == false
    assert status.status == :failed
    assert status.errors != []
  end

  test "vsm_query returns an honest error for an unknown system" do
    assert {:error, message} =
             Registry.invoke_tool("vsm_query", %{system: "s9", query: "status"})

    assert message =~ "unknown system"
  end

  test "vsm_query returns an honest error for an unsupported query" do
    assert {:error, message} =
             Registry.invoke_tool("vsm_query", %{system: "s1", query: "restart_everything"})

    assert message =~ "unsupported query"
  end

  # --- crdt_query --------------------------------------------------

  test "crdt_query executes a real GraphQueries query type" do
    start_graph()
    {:ok, _node} = Graph.add_node("builtin-probe-node", %{kind: "probe"})

    assert {:ok, result} =
             Registry.invoke_tool("crdt_query", %{
               query: "find_node",
               params: %{id: "builtin-probe-node"}
             })

    assert result.success == true
    assert result.data.id == "builtin-probe-node"
  end

  test "crdt_query surfaces GraphQueries' own error for an unknown query type" do
    start_graph()

    assert {:error, message} =
             Registry.invoke_tool("crdt_query", %{query: "bogus_query", params: %{}})

    assert message =~ "Unknown query type"
  end

  # --- telemetry_emit ----------------------------------------------

  def forward_probe(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_probe, event, measurements, metadata})
  end

  test "telemetry_emit fires the event with the given measurements and metadata" do
    handler_id = "builtin-handlers-probe"
    :telemetry.detach(handler_id)

    :ok =
      :telemetry.attach(
        handler_id,
        @probe_event,
        &__MODULE__.forward_probe/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{event: @probe_event, emitted: true}} =
             Registry.invoke_tool("telemetry_emit", %{
               event: "cybernetic.mcp.builtin_probe",
               measurements: %{count: 42},
               metadata: %{source: "builtin_test"}
             })

    assert_receive {:telemetry_probe, @probe_event, %{count: 42}, %{source: "builtin_test"}},
                   500
  end

  test "telemetry_emit rejects a malformed event name instead of raising" do
    assert {:error, message} =
             Registry.invoke_tool("telemetry_emit", %{
               event: "not a valid event!",
               measurements: %{},
               metadata: %{}
             })

    assert message =~ "invalid event name"
  end

  # --- send_telegram -----------------------------------------------

  test "send_telegram returns :telegram_unavailable when the agent is not running" do
    stop_telegram_agent()

    assert {:error, :telegram_unavailable} =
             Registry.invoke_tool("send_telegram", %{
               chat_id: "123",
               text: "hello",
               options: %{}
             })
  end

  test "send_telegram reaches a running agent and honestly reports missing configuration" do
    without_bot_token(fn ->
      pid = start_telegram_agent()
      :erlang.trace(pid, true, [:receive])

      # No bot token in the test environment: the agent cannot
      # deliver, and the tool must say so — while the message
      # still reaches the agent through its real send_message/3
      # cast API (proven by the receive trace).
      assert {:error, :telegram_not_configured} =
               Registry.invoke_tool("send_telegram", %{
                 chat_id: "123",
                 text: "hello",
                 options: %{}
               })

      assert_receive {:trace, ^pid, :receive,
                      {:"$gen_cast", {:send_message, "123", "hello", %{}}}},
                     500
    end)
  end

  # --- setup helpers -------------------------------------------------

  defp start_registry do
    {pid, started_here?} =
      case Registry.start_link([]) do
        {:ok, pid} -> {pid, true}
        {:error, {:already_started, pid}} -> {pid, false}
      end

    :ok = Registry.await_ready(2_000)

    if started_here? do
      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end

    pid
  end

  # Mirrors the stop-and-restart setup the ControlSupervisor
  # health/message tests use: the supervisor may already be
  # running under another test's process in the full suite.
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

  defp start_graph do
    case Graph.start_link([]) do
      {:ok, pid} ->
        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)

        pid

      {:error, {:already_started, pid}} ->
        pid
    end
  end

  defp stop_telegram_agent do
    if pid = Process.whereis(TelegramAgent) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp start_telegram_agent do
    case TelegramAgent.start_link([]) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp without_bot_token(fun) do
    saved = System.get_env("TELEGRAM_BOT_TOKEN")
    System.delete_env("TELEGRAM_BOT_TOKEN")

    try do
      fun.()
    after
      if saved do
        System.put_env("TELEGRAM_BOT_TOKEN", saved)
      else
        System.delete_env("TELEGRAM_BOT_TOKEN")
      end
    end
  end
end
