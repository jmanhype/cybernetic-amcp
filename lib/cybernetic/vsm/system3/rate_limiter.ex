defmodule Cybernetic.VSM.System3.RateLimiter do
  @moduledoc """
  S3 Rate Limiter for controlling resource consumption across the VSM framework.

  Provides budget management and rate limiting capabilities to prevent
  system overload and manage costs across different services.
  """

  use GenServer
  require Logger

  @telemetry [:cybernetic, :s3, :rate_limiter]

  defstruct [
    :budgets,
    :windows,
    :config
  ]

  @type budget_key :: atom()
  @type priority :: :low | :normal | :high | :critical

  # Public API

  @doc """
  Start the RateLimiter.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Request tokens from a budget.

  ## Parameters

  - budget_key: Budget identifier (e.g., :s4_llm, :s5_policy)
  - resource_type: Type of resource being consumed
  - priority: Request priority

  ## Returns

  :ok | {:error, :rate_limited}
  """
  def request_tokens(budget_key, resource_type, priority \\ :normal) do
    GenServer.call(__MODULE__, {:request_tokens, budget_key, resource_type, priority}, 5_000)
  end

  @doc """
  Get current budget status.
  """
  def budget_status(budget_key) do
    GenServer.call(__MODULE__, {:budget_status, budget_key}, 5_000)
  end

  @doc """
  Get all budget statuses.
  """
  def all_budgets do
    GenServer.call(__MODULE__, :all_budgets, 5_000)
  end

  @doc """
  Reset a budget (for testing or emergency situations).
  """
  def reset_budget(budget_key) do
    GenServer.call(__MODULE__, {:reset_budget, budget_key}, 5_000)
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    config = load_config(opts)

    state = %__MODULE__{
      budgets: initialize_budgets(config),
      windows: %{},
      config: config
    }

    Logger.info("S3 RateLimiter initialized with budgets: #{inspect(Map.keys(state.budgets))}")

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:request_tokens, budget_key, resource_type, priority}, _from, state) do
    {result, new_state} = do_request_tokens(budget_key, resource_type, priority, state)

    emit_telemetry(budget_key, resource_type, priority, result)

    {:reply, result, new_state}
  end

  @impl GenServer
  def handle_call({:budget_status, budget_key}, _from, state) do
    status = get_budget_status(budget_key, state)
    {:reply, status, state}
  end

  @impl GenServer
  def handle_call(:all_budgets, _from, state) do
    all_status =
      Enum.map(state.budgets, fn {key, _} ->
        {key, get_budget_status(key, state)}
      end)
      |> Enum.into(%{})

    {:reply, all_status, state}
  end

  @impl GenServer
  def handle_call({:reset_budget, budget_key}, _from, state) do
    new_budgets =
      case Map.get(state.budgets, budget_key) do
        nil ->
          state.budgets

        budget ->
          reset_budget = %{budget | consumed: 0, last_reset: current_time()}
          Map.put(state.budgets, budget_key, reset_budget)
      end

    new_state = %{state | budgets: new_budgets}

    Logger.info("Reset budget #{budget_key}")
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_info(:cleanup_windows, state) do
    new_state = cleanup_expired_windows(state)
    schedule_cleanup()
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp do_request_tokens(budget_key, resource_type, priority, state) do
    case Map.get(state.budgets, budget_key) do
      nil ->
        # P1 Fix: Deny by default when no budget configured (fail-closed)
        Logger.warning("Rate limiter: Unknown budget #{inspect(budget_key)}, denying request")
        {{:error, :unknown_budget}, state}

      budget ->
        case check_budget_limits(budget, resource_type, priority) do
          :ok ->
            new_budget = consume_tokens(budget, resource_type, priority)
            new_budgets = Map.put(state.budgets, budget_key, new_budget)
            new_state = %{state | budgets: new_budgets}
            {:ok, new_state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
    end
  end

  defp check_budget_limits(budget, _resource_type, priority) do
    current_time = current_time()
    window_start = current_time - budget.window_ms

    # Reset budget if window has passed
    budget =
      if budget.last_reset < window_start do
        %{budget | consumed: 0, last_reset: current_time}
      else
        budget
      end

    # Calculate priority multiplier
    multiplier =
      case priority do
        :critical -> 1
        :high -> 1
        :normal -> 2
        :low -> 4
      end

    tokens_needed = multiplier

    if budget.consumed + tokens_needed <= budget.limit do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp consume_tokens(budget, _resource_type, priority) do
    multiplier =
      case priority do
        :critical -> 1
        :high -> 1
        :normal -> 2
        :low -> 4
      end

    %{budget | consumed: budget.consumed + multiplier, last_request: current_time()}
  end

  defp get_budget_status(budget_key, state) do
    case Map.get(state.budgets, budget_key) do
      nil ->
        %{status: :not_configured}

      budget ->
        current_time = current_time()
        window_start = current_time - budget.window_ms

        # Reset consumed if window has passed
        consumed = if budget.last_reset < window_start, do: 0, else: budget.consumed

        %{
          status: :active,
          limit: budget.limit,
          consumed: consumed,
          remaining: max(0, budget.limit - consumed),
          utilization: consumed / budget.limit,
          window_ms: budget.window_ms,
          last_reset: budget.last_reset,
          last_request: budget.last_request
        }
    end
  end

  defp load_config(opts) do
    default_config = %{
      # 1 minute
      cleanup_interval: 60_000,
      # 5 minutes
      default_window: 300_000,
      default_budgets: %{
        # 100 requests per 5 minutes
        s4_llm: %{limit: 100, window_ms: 300_000},
        # 50 requests per 10 minutes
        s5_policy: %{limit: 50, window_ms: 600_000},
        # 200 requests per minute
        mcp_tools: %{limit: 200, window_ms: 60_000},
        # P1 Fix: Add api_gateway budget (used by edge gateway plugs)
        # 1000 requests per minute per client
        api_gateway: %{limit: 1000, window_ms: 60_000}
      }
    }

    app_config =
      Application.get_env(:cybernetic, :s3_rate_limiter, [])
      |> Enum.into(%{})

    opts_config =
      Keyword.take(opts, [:cleanup_interval, :default_window, :default_budgets])
      |> Enum.into(%{})

    Map.merge(default_config, Map.merge(app_config, opts_config))
  end

  defp initialize_budgets(config) do
    current_time = current_time()

    config.default_budgets
    |> Enum.map(fn {key, budget_config} ->
      budget = %{
        limit: budget_config.limit,
        window_ms: budget_config.window_ms,
        consumed: 0,
        last_reset: current_time,
        last_request: nil
      }

      {key, budget}
    end)
    |> Enum.into(%{})
  end

  defp cleanup_expired_windows(state) do
    # For now, just return the state as windows are managed per-budget
    state
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_windows, 60_000)
  end

  defp current_time do
    System.monotonic_time(:millisecond)
  end

  defp emit_telemetry(budget_key, resource_type, priority, result) do
    measurements = %{count: 1}

    metadata = %{
      budget_key: budget_key,
      resource_type: resource_type,
      priority: priority,
      result:
        case result do
          :ok -> :allowed
          {:error, reason} -> reason
        end
    }

    :telemetry.execute(@telemetry, measurements, metadata)
  end
end
