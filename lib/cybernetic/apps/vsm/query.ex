defmodule Cybernetic.Apps.VSM.Query do
  @moduledoc """
  Handler behind the MCP registry's `vsm_query` tool
  ("Query VSM system state").

  The tool was registered against this module before it existed,
  so every invocation failed with an undefined-function error.
  This implementation backs the tool with the real status
  surfaces:

  - S3 answers from
    `Cybernetic.VSM.System3.ControlSupervisor.get_status/0`, the
    control system's own status map.
  - S1/S2/S4/S5 are probed through the process that represents
    them — the same kind of probe S3's own health checks use —
    reporting the process's real message-queue length and memory.

  Supported queries: `"status"` and `"health"`. A system whose
  process is not running reports an honest `:failed` status;
  nothing is fabricated for it. Unknown systems and unknown
  queries return `{:error, message}`.
  """

  alias Cybernetic.VSM.System1
  alias Cybernetic.VSM.System2
  alias Cybernetic.VSM.System3.ControlSupervisor
  alias Cybernetic.VSM.System4
  alias Cybernetic.VSM.System5

  @systems %{
    system1: System1.Operational,
    system2: System2.Coordinator,
    system3: ControlSupervisor,
    system4: System4.Intelligence,
    system5: System5.Policy
  }

  @system_names %{
    "s1" => :system1,
    "system1" => :system1,
    "s2" => :system2,
    "system2" => :system2,
    "s3" => :system3,
    "system3" => :system3,
    "s4" => :system4,
    "system4" => :system4,
    "s5" => :system5,
    "system5" => :system5
  }

  @doc """
  Execute a VSM query.

  `params` carries `:system` (`"s1"`..`"s5"`, `"system1"`..`"system5"`,
  or the system atom) and `:query` (`"status"` or `"health"`).
  Atom and string keys are both accepted.
  """
  @spec execute(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute(params, _context \\ %{}) when is_map(params) do
    with {:ok, system} <- fetch_system(params),
         {:ok, query} <- fetch_query(params) do
      run_query(system, query)
    end
  end

  # Query execution

  defp run_query(:system3, :status) do
    case Process.whereis(ControlSupervisor) do
      nil -> {:ok, down_status(:system3)}
      _pid -> {:ok, ControlSupervisor.get_status() |> Map.put(:system, :system3)}
    end
  end

  defp run_query(system, :status) do
    {:ok, probe_status(system)}
  end

  defp run_query(:system3, :health) do
    case Process.whereis(ControlSupervisor) do
      nil ->
        {:ok, %{system: :system3, health: :failed, running: false}}

      _pid ->
        status = ControlSupervisor.get_status()
        {:ok, %{system: :system3, health: status.health_status, running: true}}
    end
  end

  defp run_query(system, :health) do
    status = probe_status(system)
    health = if status.running, do: :healthy, else: :failed
    {:ok, %{system: system, health: health, running: status.running}}
  end

  # Real per-system probe: a live front process reports its actual
  # queue length and memory; a missing one is a failed system,
  # mirroring ControlSupervisor's own query_system_status semantics.
  defp probe_status(system) do
    case Process.whereis(@systems[system]) do
      nil ->
        down_status(system)

      pid ->
        info = Process.info(pid, [:message_queue_len, :memory])

        %{
          system: system,
          running: true,
          metrics: %{
            message_queue_len: info[:message_queue_len],
            memory: info[:memory]
          },
          errors: []
        }
    end
  end

  defp down_status(system) do
    %{
      system: system,
      running: false,
      status: :failed,
      metrics: %{},
      errors: ["#{inspect(@systems[system])} process is not running"]
    }
  end

  # Parameter handling

  defp fetch_system(params) do
    case params[:system] || params["system"] do
      nil ->
        {:error, "missing required parameter: system"}

      raw ->
        case normalize_system(raw) do
          nil -> {:error, "unknown system: #{inspect(raw)}"}
          system -> {:ok, system}
        end
    end
  end

  defp normalize_system(raw) when is_atom(raw) do
    if Map.has_key?(@systems, raw), do: raw
  end

  defp normalize_system(raw) when is_binary(raw) do
    Map.get(@system_names, raw |> String.trim() |> String.downcase())
  end

  defp normalize_system(_raw), do: nil

  defp fetch_query(params) do
    case params[:query] || params["query"] do
      nil ->
        {:error, "missing required parameter: query"}

      raw ->
        case normalize_query(raw) do
          nil -> {:error, "unsupported query: #{inspect(raw)}"}
          query -> {:ok, query}
        end
    end
  end

  defp normalize_query(raw) when raw in [:status, "status"], do: :status
  defp normalize_query(raw) when raw in [:health, "health"], do: :health
  defp normalize_query(_raw), do: nil
end
