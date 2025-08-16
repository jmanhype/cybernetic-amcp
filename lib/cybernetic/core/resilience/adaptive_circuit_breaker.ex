defmodule Cybernetic.Core.Resilience.AdaptiveCircuitBreaker do
  @moduledoc """
  Adaptive circuit breaker with machine learning-based threshold adjustment.
  
  Features:
  - Dynamic failure threshold based on historical patterns
  - Exponential backoff with jitter
  - Health scoring with decay
  - Integration with VSM S3 control system
  - Automatic recovery testing
  """
  use GenServer
  require Logger

  @default_failure_threshold 5
  @default_success_threshold 3
  @default_timeout_ms 60_000
  @default_health_decay 0.95
  @default_adaptation_rate 0.1

  defstruct [
    :name,
    :state,  # :closed, :open, :half_open
    :failure_count,
    :success_count,
    :last_failure_time,
    :timeout_ms,
    :failure_threshold,
    :success_threshold,
    :health_score,
    :health_decay,
    :adaptation_rate,
    :failure_history,
    :success_history,
    :adaptive_threshold,
    :recovery_timer
  ]

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via_name(name))
  end

  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    
    state = %__MODULE__{
      name: name,
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil,
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      success_threshold: Keyword.get(opts, :success_threshold, @default_success_threshold),
      health_score: 1.0,
      health_decay: Keyword.get(opts, :health_decay, @default_health_decay),
      adaptation_rate: Keyword.get(opts, :adaptation_rate, @default_adaptation_rate),
      failure_history: :queue.new(),
      success_history: :queue.new(),
      adaptive_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      recovery_timer: nil
    }
    
    # Attach to telemetry for system health monitoring
    attach_health_monitoring(name)
    
    Logger.info("Adaptive circuit breaker '#{name}' initialized")
    {:ok, state}
  end

  @doc """
  Execute a function with circuit breaker protection.
  """
  def call(name, fun, timeout \\ 5000) when is_function(fun, 0) do
    GenServer.call(via_name(name), {:call, fun}, timeout)
  end

  @doc """
  Record a successful operation.
  """
  def record_success(name) do
    GenServer.cast(via_name(name), :record_success)
  end

  @doc """
  Record a failed operation.
  """
  def record_failure(name, error \\ nil) do
    GenServer.cast(via_name(name), {:record_failure, error})
  end

  @doc """
  Get current state and statistics.
  """
  def get_state(name) do
    GenServer.call(via_name(name), :get_state)
  end

  @doc """
  Force state transition (for testing/manual control).
  """
  def force_state(name, new_state) when new_state in [:closed, :open, :half_open] do
    GenServer.cast(via_name(name), {:force_state, new_state})
  end

  @doc """
  Reset circuit breaker to initial state.
  """
  def reset(name) do
    GenServer.cast(via_name(name), :reset)
  end

  # GenServer callbacks

  def handle_call({:call, fun}, _from, state) do
    case state.state do
      :closed ->
        execute_and_handle_result(fun, state)
      
      :open ->
        if should_attempt_recovery?(state) do
          # Transition to half-open and try
          new_state = transition_to_half_open(state)
          execute_and_handle_result(fun, new_state)
        else
          emit_circuit_breaker_telemetry(state, :rejected)
          {:reply, {:error, :circuit_breaker_open}, state}
        end
      
      :half_open ->
        execute_and_handle_result(fun, state)
    end
  end

  def handle_call(:get_state, _from, state) do
    stats = %{
      name: state.name,
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      health_score: state.health_score,
      adaptive_threshold: state.adaptive_threshold,
      last_failure_time: state.last_failure_time,
      timeout_ms: state.timeout_ms
    }
    {:reply, stats, state}
  end

  def handle_cast(:record_success, state) do
    new_state = handle_success(state)
    {:noreply, new_state}
  end

  def handle_cast({:record_failure, error}, state) do
    new_state = handle_failure(state, error)
    {:noreply, new_state}
  end

  def handle_cast({:force_state, new_state_value}, state) do
    Logger.info("Circuit breaker '#{state.name}' forced to state: #{new_state_value}")
    new_state = %{state | state: new_state_value}
    {:noreply, new_state}
  end

  def handle_cast(:reset, state) do
    Logger.info("Circuit breaker '#{state.name}' reset")
    new_state = %{state |
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil,
      health_score: 1.0,
      failure_history: :queue.new(),
      success_history: :queue.new(),
      recovery_timer: cancel_recovery_timer(state.recovery_timer)
    }
    {:noreply, new_state}
  end

  def handle_info(:attempt_recovery, state) do
    if state.state == :open do
      new_state = transition_to_half_open(state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:health_update, health_metrics}, state) do
    new_state = update_adaptive_threshold(state, health_metrics)
    {:noreply, new_state}
  end

  # Private helper functions

  defp via_name(name), do: {:via, Registry, {Cybernetic.CircuitBreakerRegistry, name}}

  defp execute_and_handle_result(fun, state) do
    start_time = System.monotonic_time(:microsecond)
    
    try do
      result = fun.()
      duration = System.monotonic_time(:microsecond) - start_time
      
      new_state = handle_success(state)
      emit_circuit_breaker_telemetry(new_state, :success, %{duration_us: duration})
      
      {:reply, {:ok, result}, new_state}
    rescue
      error ->
        duration = System.monotonic_time(:microsecond) - start_time
        
        new_state = handle_failure(state, error)
        emit_circuit_breaker_telemetry(new_state, :failure, %{
          duration_us: duration,
          error: error.__struct__
        })
        
        {:reply, {:error, error}, new_state}
    catch
      :exit, reason ->
        new_state = handle_failure(state, reason)
        emit_circuit_breaker_telemetry(new_state, :failure, %{exit_reason: reason})
        
        {:reply, {:error, {:exit, reason}}, new_state}
    end
  end

  defp handle_success(state) do
    new_success_count = state.success_count + 1
    new_health_score = min(1.0, state.health_score + 0.1)
    
    # Add to success history (keep last 100)
    new_success_history = add_to_history(state.success_history, System.monotonic_time(:millisecond), 100)
    
    new_state = %{state |
      success_count: new_success_count,
      health_score: new_health_score,
      success_history: new_success_history
    }
    
    case state.state do
      :half_open ->
        if new_success_count >= state.success_threshold do
          transition_to_closed(new_state)
        else
          new_state
        end
      
      _ ->
        new_state
    end
  end

  defp handle_failure(state, error) do
    now = System.monotonic_time(:millisecond)
    new_failure_count = state.failure_count + 1
    new_health_score = max(0.0, state.health_score - 0.2)
    
    # Add to failure history (keep last 100)
    new_failure_history = add_to_history(state.failure_history, now, 100)
    
    new_state = %{state |
      failure_count: new_failure_count,
      last_failure_time: now,
      health_score: new_health_score,
      failure_history: new_failure_history
    }
    
    Logger.warning("Circuit breaker '#{state.name}' recorded failure: #{inspect(error)}")
    
    if should_open_circuit?(new_state) do
      transition_to_open(new_state)
    else
      new_state
    end
  end

  defp should_open_circuit?(state) do
    state.failure_count >= state.adaptive_threshold
  end

  defp should_attempt_recovery?(state) do
    case state.last_failure_time do
      nil -> true
      last_failure ->
        elapsed = System.monotonic_time(:millisecond) - last_failure
        elapsed >= state.timeout_ms
    end
  end

  defp transition_to_open(state) do
    Logger.warning("Circuit breaker '#{state.name}' opening (failures: #{state.failure_count})")
    
    # Schedule recovery attempt with exponential backoff
    backoff_time = calculate_backoff(state.failure_count, state.timeout_ms)
    recovery_timer = Process.send_after(self(), :attempt_recovery, backoff_time)
    
    emit_circuit_breaker_telemetry(state, :opened)
    
    # Notify S3 control system
    notify_s3_control(state.name, :circuit_opened, %{
      failure_count: state.failure_count,
      health_score: state.health_score
    })
    
    %{state |
      state: :open,
      success_count: 0,
      recovery_timer: recovery_timer
    }
  end

  defp transition_to_half_open(state) do
    Logger.info("Circuit breaker '#{state.name}' transitioning to half-open")
    emit_circuit_breaker_telemetry(state, :half_opened)
    
    %{state |
      state: :half_open,
      success_count: 0,
      recovery_timer: cancel_recovery_timer(state.recovery_timer)
    }
  end

  defp transition_to_closed(state) do
    Logger.info("Circuit breaker '#{state.name}' closing (recovered)")
    emit_circuit_breaker_telemetry(state, :closed)
    
    # Notify S3 control system of recovery
    notify_s3_control(state.name, :circuit_recovered, %{
      success_count: state.success_count,
      health_score: state.health_score
    })
    
    %{state |
      state: :closed,
      failure_count: 0,
      success_count: 0
    }
  end

  defp update_adaptive_threshold(state, health_metrics) do
    # Adapt threshold based on system health
    system_health = Map.get(health_metrics, :overall_health, 0.5)
    error_rate = Map.get(health_metrics, :error_rate, 0.1)
    
    # Calculate new threshold using exponential moving average
    base_threshold = state.failure_threshold
    health_factor = if system_health > 0.8, do: 1.2, else: 0.8
    error_factor = max(0.5, 1.0 - error_rate)
    
    suggested_threshold = base_threshold * health_factor * error_factor
    
    new_adaptive_threshold = 
      state.adaptive_threshold * (1 - state.adaptation_rate) + 
      suggested_threshold * state.adaptation_rate
    
    # Clamp to reasonable bounds
    clamped_threshold = max(2, min(20, new_adaptive_threshold))
    
    if abs(clamped_threshold - state.adaptive_threshold) > 1 do
      Logger.debug("Circuit breaker '#{state.name}' adaptive threshold: #{state.adaptive_threshold} -> #{clamped_threshold}")
    end
    
    %{state | adaptive_threshold: clamped_threshold}
  end

  defp calculate_backoff(failure_count, base_timeout) do
    # Exponential backoff with jitter
    exponential = min(base_timeout * :math.pow(2, failure_count - 1), 300_000)  # Max 5 minutes
    jitter = :rand.uniform(trunc(exponential * 0.1))  # ±10% jitter
    trunc(exponential + jitter)
  end

  defp add_to_history(history, timestamp, max_size) do
    new_history = :queue.in(timestamp, history)
    
    if :queue.len(new_history) > max_size do
      {_, trimmed} = :queue.out(new_history)
      trimmed
    else
      new_history
    end
  end

  defp cancel_recovery_timer(nil), do: nil
  defp cancel_recovery_timer(timer) do
    Process.cancel_timer(timer)
    nil
  end

  defp emit_circuit_breaker_telemetry(state, event, metadata \\ %{}) do
    base_metadata = %{
      circuit_breaker: state.name,
      state: state.state,
      health_score: state.health_score,
      adaptive_threshold: state.adaptive_threshold
    }
    
    full_metadata = Map.merge(base_metadata, metadata)
    
    measurements = %{
      failure_count: state.failure_count,
      success_count: state.success_count
    }
    
    :telemetry.execute([:cyb, :circuit_breaker, event], measurements, full_metadata)
  end

  defp attach_health_monitoring(name) do
    # Subscribe to system health updates
    :telemetry.attach(
      {:circuit_breaker_health, name},
      [:cybernetic, :system, :health],
      fn _event, measurements, _metadata, _config ->
        GenServer.cast(via_name(name), {:health_update, measurements})
      end,
      nil
    )
  end

  defp notify_s3_control(breaker_name, event, data) do
    case Process.whereis(Cybernetic.VSM.System3.ControlSupervisor) do
      nil ->
        Logger.debug("S3 ControlSupervisor not available for circuit breaker notification")
      
      pid ->
        GenServer.cast(pid, {:circuit_breaker_event, breaker_name, event, data})
    end
  end
end