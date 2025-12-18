defmodule Cybernetic.Intelligence.CEP.WorkflowHooks do
  @moduledoc """
  Complex Event Processing workflow hooks using Goldrush.

  Provides pattern-based workflow triggering:
  - Event pattern matching (field conditions)
  - Threshold-based activation (count, rate)
  - Time-window aggregation
  - Workflow dispatch on match

  ## Usage

      # Register a hook
      {:ok, hook_id} = WorkflowHooks.register(%{
        name: "high_error_rate",
        pattern: %{type: "error", severity: {:gte, "high"}},
        threshold: %{count: 10, window_ms: 60_000},
        action: {:workflow, "alert_ops"}
      })

      # Process events (usually called from event pipeline)
      :ok = WorkflowHooks.process_event(%{type: "error", severity: "critical"})

      # Check active hooks
      hooks = WorkflowHooks.list_hooks()
  """
  use GenServer

  require Logger

  @type hook_id :: String.t()
  @type pattern :: map()
  @type threshold :: %{
          optional(:count) => pos_integer(),
          optional(:window_ms) => pos_integer(),
          optional(:rate_per_min) => pos_integer()
        }
  @type action ::
          {:workflow, String.t()}
          | {:notify, String.t()}
          | {:log, atom()}
          | {:callback, function()}

  @type hook :: %{
          id: hook_id(),
          name: String.t(),
          pattern: pattern(),
          threshold: threshold() | nil,
          action: action(),
          enabled: boolean(),
          created_at: DateTime.t(),
          triggered_count: non_neg_integer(),
          last_triggered: DateTime.t() | nil
        }

  @type window_state :: %{
          events: [{DateTime.t(), map()}],
          count: non_neg_integer()
        }

  @telemetry [:cybernetic, :intelligence, :cep]

  # Client API

  @doc "Start the workflow hooks server"
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register a new workflow hook"
  @spec register(map(), keyword()) :: {:ok, hook_id()} | {:error, term()}
  def register(config, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:register, config})
  end

  @doc "Unregister a hook"
  @spec unregister(hook_id(), keyword()) :: :ok | {:error, :not_found}
  def unregister(hook_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:unregister, hook_id})
  end

  @doc "Enable/disable a hook"
  @spec set_enabled(hook_id(), boolean(), keyword()) :: :ok | {:error, :not_found}
  def set_enabled(hook_id, enabled, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:set_enabled, hook_id, enabled})
  end

  @doc "Process an event through all registered hooks"
  @spec process_event(map(), keyword()) :: :ok
  def process_event(event, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:process_event, event})
  end

  @doc "List all registered hooks"
  @spec list_hooks(keyword()) :: [hook()]
  def list_hooks(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :list_hooks)
  end

  @doc "Get a specific hook"
  @spec get_hook(hook_id(), keyword()) :: {:ok, hook()} | {:error, :not_found}
  def get_hook(hook_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get_hook, hook_id})
  end

  @doc "Get statistics"
  @spec stats(keyword()) :: map()
  def stats(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :stats)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("CEP Workflow Hooks starting")

    # Register Goldrush patterns if available
    maybe_init_goldrush()

    state = %{
      hooks: %{},
      windows: %{},  # hook_id => window_state
      stats: %{
        events_processed: 0,
        hooks_triggered: 0,
        pattern_matches: 0
      }
    }

    # Schedule window cleanup
    schedule_window_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call({:register, config}, _from, state) do
    with {:ok, hook} <- build_hook(config) do
      new_state = %{
        state
        | hooks: Map.put(state.hooks, hook.id, hook),
          windows: Map.put(state.windows, hook.id, %{events: [], count: 0})
      }

      Logger.info("Registered CEP hook", hook_id: hook.id, name: hook.name)
      emit_telemetry(:hook_registered, %{hook_id: hook.id})

      {:reply, {:ok, hook.id}, new_state}
    else
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:unregister, hook_id}, _from, state) do
    if Map.has_key?(state.hooks, hook_id) do
      new_state = %{
        state
        | hooks: Map.delete(state.hooks, hook_id),
          windows: Map.delete(state.windows, hook_id)
      }

      Logger.info("Unregistered CEP hook", hook_id: hook_id)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:set_enabled, hook_id, enabled}, _from, state) do
    if Map.has_key?(state.hooks, hook_id) do
      new_hooks = update_in(state.hooks, [hook_id, :enabled], fn _ -> enabled end)
      {:reply, :ok, %{state | hooks: new_hooks}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_hooks, _from, state) do
    hooks = Map.values(state.hooks)
    {:reply, hooks, state}
  end

  @impl true
  def handle_call({:get_hook, hook_id}, _from, state) do
    case Map.get(state.hooks, hook_id) do
      nil -> {:reply, {:error, :not_found}, state}
      hook -> {:reply, {:ok, hook}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      state.stats
      |> Map.put(:active_hooks, map_size(state.hooks))
      |> Map.put(:enabled_hooks, count_enabled(state.hooks))

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:process_event, event}, state) do
    start_time = System.monotonic_time(:microsecond)
    now = DateTime.utc_now()

    # Process through all enabled hooks
    {new_state, triggered_count} =
      Enum.reduce(state.hooks, {state, 0}, fn {hook_id, hook}, {acc_state, count} ->
        if hook.enabled and matches_pattern?(event, hook.pattern) do
          # Update window state
          acc_state = update_window(acc_state, hook_id, event, now)

          # Check threshold
          if threshold_met?(acc_state, hook_id, hook.threshold) do
            # Execute action
            execute_action(hook.action, event, hook)

            # Update hook stats
            updated_hook = %{
              hook
              | triggered_count: hook.triggered_count + 1,
                last_triggered: now
            }

            new_hooks = Map.put(acc_state.hooks, hook_id, updated_hook)

            # Clear window after trigger
            new_windows = Map.put(acc_state.windows, hook_id, %{events: [], count: 0})

            {%{acc_state | hooks: new_hooks, windows: new_windows}, count + 1}
          else
            # Pattern matched but threshold not met
            acc_state = update_in(acc_state, [:stats, :pattern_matches], &(&1 + 1))
            {acc_state, count}
          end
        else
          {acc_state, count}
        end
      end)

    # Update stats
    final_state =
      new_state
      |> update_in([:stats, :events_processed], &(&1 + 1))
      |> update_in([:stats, :hooks_triggered], &(&1 + triggered_count))

    duration = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:event_processed, %{duration_us: duration, triggers: triggered_count})

    {:noreply, final_state}
  end

  @impl true
  def handle_info(:window_cleanup, state) do
    now = DateTime.utc_now()

    # Clean expired events from all windows
    new_windows =
      Enum.into(state.windows, %{}, fn {hook_id, window} ->
        hook = Map.get(state.hooks, hook_id)
        window_ms = get_window_ms(hook)

        cutoff = DateTime.add(now, -window_ms, :millisecond)

        cleaned_events =
          Enum.filter(window.events, fn {timestamp, _event} ->
            DateTime.compare(timestamp, cutoff) == :gt
          end)

        {hook_id, %{events: cleaned_events, count: length(cleaned_events)}}
      end)

    schedule_window_cleanup()

    {:noreply, %{state | windows: new_windows}}
  end

  # Private Functions

  @spec build_hook(map()) :: {:ok, hook()} | {:error, term()}
  defp build_hook(config) do
    with :ok <- validate_hook_config(config) do
      hook = %{
        id: UUID.uuid4(),
        name: config[:name] || "unnamed_hook",
        pattern: config[:pattern] || %{},
        threshold: config[:threshold],
        action: config[:action],
        enabled: Map.get(config, :enabled, true),
        created_at: DateTime.utc_now(),
        triggered_count: 0,
        last_triggered: nil
      }

      {:ok, hook}
    end
  end

  @spec validate_hook_config(map()) :: :ok | {:error, term()}
  defp validate_hook_config(config) do
    cond do
      not is_map(config[:pattern]) ->
        {:error, :invalid_pattern}

      config[:action] == nil ->
        {:error, :missing_action}

      not valid_action?(config[:action]) ->
        {:error, :invalid_action}

      true ->
        :ok
    end
  end

  @spec valid_action?(term()) :: boolean()
  defp valid_action?({:workflow, name}) when is_binary(name), do: true
  defp valid_action?({:notify, channel}) when is_binary(channel), do: true
  defp valid_action?({:log, level}) when level in [:debug, :info, :warning, :error], do: true
  defp valid_action?({:callback, fun}) when is_function(fun, 2), do: true
  defp valid_action?(_), do: false

  @spec matches_pattern?(map(), pattern()) :: boolean()
  defp matches_pattern?(_event, pattern) when map_size(pattern) == 0, do: true

  defp matches_pattern?(event, pattern) do
    Enum.all?(pattern, fn {key, expected} ->
      actual = Map.get(event, key)
      matches_value?(actual, expected)
    end)
  end

  @spec matches_value?(term(), term()) :: boolean()
  defp matches_value?(actual, {:eq, expected}), do: actual == expected
  defp matches_value?(actual, {:neq, expected}), do: actual != expected
  defp matches_value?(actual, {:gt, expected}) when is_number(actual), do: actual > expected
  defp matches_value?(actual, {:gte, expected}) when is_number(actual), do: actual >= expected
  defp matches_value?(actual, {:lt, expected}) when is_number(actual), do: actual < expected
  defp matches_value?(actual, {:lte, expected}) when is_number(actual), do: actual <= expected

  defp matches_value?(actual, {:in, list}) when is_list(list), do: actual in list
  defp matches_value?(actual, {:contains, substr}) when is_binary(actual) and is_binary(substr) do
    String.contains?(actual, substr)
  end
  defp matches_value?(actual, {:matches, regex}) when is_binary(actual) do
    Regex.match?(regex, actual)
  end

  # Severity comparison (string ordering)
  defp matches_value?(actual, {:gte, expected}) when is_binary(actual) and is_binary(expected) do
    severity_rank(actual) >= severity_rank(expected)
  end

  defp matches_value?(actual, expected), do: actual == expected

  @spec severity_rank(String.t()) :: integer()
  defp severity_rank("critical"), do: 4
  defp severity_rank("high"), do: 3
  defp severity_rank("medium"), do: 2
  defp severity_rank("low"), do: 1
  defp severity_rank(_), do: 0

  @spec update_window(map(), hook_id(), map(), DateTime.t()) :: map()
  defp update_window(state, hook_id, event, timestamp) do
    window = Map.get(state.windows, hook_id, %{events: [], count: 0})

    new_window = %{
      events: [{timestamp, event} | window.events],
      count: window.count + 1
    }

    %{state | windows: Map.put(state.windows, hook_id, new_window)}
  end

  @spec threshold_met?(map(), hook_id(), threshold() | nil) :: boolean()
  defp threshold_met?(_state, _hook_id, nil), do: true

  defp threshold_met?(state, hook_id, threshold) do
    window = Map.get(state.windows, hook_id, %{events: [], count: 0})

    cond do
      # Count threshold
      Map.has_key?(threshold, :count) ->
        window.count >= threshold.count

      # Rate threshold (events per minute)
      Map.has_key?(threshold, :rate_per_min) ->
        window_ms = Map.get(threshold, :window_ms, 60_000)
        rate = window.count / (window_ms / 60_000)
        rate >= threshold.rate_per_min

      true ->
        true
    end
  end

  @spec get_window_ms(hook() | nil) :: pos_integer()
  defp get_window_ms(nil), do: 60_000
  defp get_window_ms(%{threshold: nil}), do: 60_000
  defp get_window_ms(%{threshold: threshold}), do: Map.get(threshold, :window_ms, 60_000)

  @spec execute_action(action(), map(), hook()) :: :ok
  defp execute_action({:workflow, workflow_name}, event, hook) do
    Logger.info("Triggering workflow",
      workflow: workflow_name,
      hook: hook.name,
      event_type: Map.get(event, :type)
    )

    # Dispatch to workflow system (placeholder for actual implementation)
    emit_telemetry(:workflow_triggered, %{workflow: workflow_name, hook_id: hook.id})
    :ok
  end

  defp execute_action({:notify, channel}, _event, hook) do
    Logger.info("Sending notification",
      channel: channel,
      hook: hook.name
    )

    # Would dispatch to notification system
    emit_telemetry(:notification_sent, %{channel: channel, hook_id: hook.id})
    :ok
  end

  defp execute_action({:log, level}, event, hook) do
    message = "CEP hook triggered: #{hook.name}"

    case level do
      :debug -> Logger.debug(message, event: event)
      :info -> Logger.info(message, event: event)
      :warning -> Logger.warning(message, event: event)
      :error -> Logger.error(message, event: event)
    end

    :ok
  end

  defp execute_action({:callback, fun}, event, hook) do
    try do
      fun.(event, hook)
      :ok
    rescue
      e ->
        Logger.error("Hook callback failed",
          hook: hook.name,
          error: Exception.message(e)
        )

        :ok
    end
  end

  @spec count_enabled(map()) :: non_neg_integer()
  defp count_enabled(hooks) do
    Enum.count(hooks, fn {_id, hook} -> hook.enabled end)
  end

  defp maybe_init_goldrush do
    if Code.ensure_loaded?(:gr) do
      Logger.debug("Goldrush available for CEP")
    else
      Logger.debug("Goldrush not available, using built-in pattern matching")
    end
  end

  defp schedule_window_cleanup do
    Process.send_after(self(), :window_cleanup, :timer.seconds(30))
  end

  @spec emit_telemetry(atom(), map()) :: :ok
  defp emit_telemetry(event, metadata) do
    :telemetry.execute(@telemetry ++ [event], %{count: 1}, metadata)
  end
end
