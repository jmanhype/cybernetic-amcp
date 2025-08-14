defmodule Cybernetic.Telemetry.Metrics do
  @moduledoc """
  Telemetry metrics definitions for Cybernetic system monitoring.
  Provides standardized metrics for Prometheus export and dashboards.
  """
  
  use Supervisor
  import Telemetry.Metrics
  
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end
  
  @impl true
  def init(_arg) do
    children = [
      # Add telemetry poller for periodic measurements
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
  
  @doc """
  Core metrics for system observability
  """
  def metrics do
    [
      # MCP Registry
      summary("cybernetic.mcp_registry.ready.count",
        description: "Number of MCP tools registered",
        unit: {:native, :count}
      ),
      
      # NonceBloom Security
      counter("cybernetic.security.nonce_bloom.cleanup.dropped",
        description: "Nonces dropped during cleanup",
        unit: {:native, :count}
      ),
      counter("cybernetic.security.nonce_bloom.cleanup.kept",
        description: "Nonces kept during cleanup",
        unit: {:native, :count}
      ),
      distribution("cybernetic.security.nonce_bloom.clock_skew.skew_ms",
        description: "Clock skew in milliseconds",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 500, 1000, 5000, 10000, 30000, 60000, 90000]]
      ),
      
      # AMQP Transport
      last_value("cybernetic.amqp.connection.status",
        description: "AMQP connection status (1=up, 0=down)",
        unit: {:native, :boolean}
      ),
      counter("cybernetic.amqp.messages.published",
        description: "Total messages published",
        tags: [:exchange, :routing_key]
      ),
      counter("cybernetic.amqp.messages.consumed",
        description: "Total messages consumed",
        tags: [:queue, :consumer]
      ),
      counter("cybernetic.amqp.messages.rejected",
        description: "Messages rejected",
        tags: [:queue, :reason]
      ),
      distribution("cybernetic.amqp.rtt.ms",
        description: "AMQP round-trip time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [5, 10, 20, 40, 80, 160, 320, 640, 1280]]
      ),
      
      # VSM Systems
      counter("cybernetic.vsm.messages.processed",
        description: "Messages processed by VSM system",
        tags: [:system, :operation]
      ),
      summary("cybernetic.vsm.processing_time.ms",
        description: "VSM message processing time",
        tags: [:system],
        unit: {:native, :millisecond}
      ),
      
      # Algedonic Signals
      counter("cybernetic.algedonic.signals",
        description: "Algedonic signals emitted",
        tags: [:severity, :source]
      ),
      
      # CRDT State
      last_value("cybernetic.crdt.size",
        description: "CRDT state size",
        unit: {:byte, :kilobyte}
      ),
      counter("cybernetic.crdt.merges",
        description: "CRDT merge operations"
      ),
      
      # System Health
      last_value("vm.memory.total",
        unit: {:byte, :megabyte}
      ),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.system_counts.process_count")
    ]
  end
  
  @doc """
  Periodic measurements for system metrics
  """
  def periodic_measurements do
    [
      # Check AMQP connection status
      {__MODULE__, :measure_amqp_status, []},
      
      # Measure CRDT size
      {__MODULE__, :measure_crdt_size, []},
      
      # Custom VM stats
      {__MODULE__, :measure_vm_stats, []}
    ]
  end
  
  def measure_amqp_status do
    status = case Process.whereis(Cybernetic.Transport.AMQP.Connection) do
      nil -> 0
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: 1, else: 0
    end
    
    :telemetry.execute(
      [:cybernetic, :amqp, :connection],
      %{status: status},
      %{}
    )
  end
  
  def measure_crdt_size do
    # Measure CRDT state size if available
    case Process.whereis(Cybernetic.Core.CRDT.ContextGraph) do
      nil -> :ok
      pid ->
        try do
          state_size = GenServer.call(pid, :get_size, 100)
          :telemetry.execute(
            [:cybernetic, :crdt],
            %{size: state_size},
            %{}
          )
        catch
          :exit, _ -> :ok
        end
    end
  end
  
  def measure_vm_stats do
    :telemetry.execute(
      [:vm, :memory],
      %{total: :erlang.memory(:total)},
      %{}
    )
    
    :telemetry.execute(
      [:vm, :system_counts],
      %{process_count: :erlang.system_info(:process_count)},
      %{}
    )
  end
end