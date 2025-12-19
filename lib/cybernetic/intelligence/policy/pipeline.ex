defmodule Cybernetic.Intelligence.Policy.Pipeline do
  @moduledoc """
  Policy lifecycle pipeline: compile → deploy → evaluate.

  Manages policy storage, versioning, and evaluation with support for:
  - Hot policy updates without restart
  - Version rollback
  - A/B testing with policy variants
  - Audit logging
  """

  use GenServer
  require Logger

  alias Cybernetic.Intelligence.Policy.{DSL, Runtime}

  @type policy_id :: String.t()
  @type version :: pos_integer()

  defstruct [
    :policies,
    :active_versions,
    :stats
  ]

  # Public API

  @doc """
  Start the policy pipeline GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a policy from DSL source.
  """
  @spec register(String.t(), String.t(), keyword()) :: {:ok, version()} | {:error, term()}
  def register(policy_id, source, opts \\ []) when is_binary(policy_id) and is_binary(source) do
    GenServer.call(__MODULE__, {:register, policy_id, source, opts})
  end

  @doc """
  Register a policy from rules list.
  """
  @spec register_rules(String.t(), [tuple()], keyword()) :: {:ok, version()} | {:error, term()}
  def register_rules(policy_id, rules, opts \\ []) when is_binary(policy_id) and is_list(rules) do
    GenServer.call(__MODULE__, {:register_rules, policy_id, rules, opts})
  end

  @doc """
  Evaluate a policy.
  """
  @spec evaluate(String.t(), Runtime.eval_context(), keyword()) :: Runtime.result()
  def evaluate(policy_id, eval_context, opts \\ []) when is_binary(policy_id) do
    GenServer.call(__MODULE__, {:evaluate, policy_id, eval_context, opts})
  end

  @doc """
  Evaluate multiple policies.
  """
  @spec evaluate_all([String.t()], Runtime.eval_context(), keyword()) :: Runtime.result()
  def evaluate_all(policy_ids, eval_context, opts \\ []) when is_list(policy_ids) do
    GenServer.call(__MODULE__, {:evaluate_all, policy_ids, eval_context, opts})
  end

  @doc """
  Get active version of a policy.
  """
  @spec get_active_version(String.t()) :: {:ok, version()} | {:error, :not_found}
  def get_active_version(policy_id) when is_binary(policy_id) do
    GenServer.call(__MODULE__, {:get_active_version, policy_id})
  end

  @doc """
  Set active version (rollback/rollforward).
  """
  @spec set_active_version(String.t(), version()) :: :ok | {:error, term()}
  def set_active_version(policy_id, version) when is_binary(policy_id) and is_integer(version) do
    GenServer.call(__MODULE__, {:set_active_version, policy_id, version})
  end

  @doc """
  List all policy versions.
  """
  @spec list_versions(String.t()) :: [version()]
  def list_versions(policy_id) when is_binary(policy_id) do
    GenServer.call(__MODULE__, {:list_versions, policy_id})
  end

  @doc """
  Delete a policy and all versions.
  """
  @spec delete(String.t()) :: :ok
  def delete(policy_id) when is_binary(policy_id) do
    GenServer.call(__MODULE__, {:delete, policy_id})
  end

  @doc """
  Get pipeline statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  List all registered policy IDs.
  """
  @spec list_policies() :: [String.t()]
  def list_policies do
    GenServer.call(__MODULE__, :list_policies)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      policies: %{},
      active_versions: %{},
      stats: %{
        evaluations: 0,
        allows: 0,
        denies: 0,
        errors: 0,
        avg_eval_time_us: 0
      }
    }

    Logger.info("Policy pipeline started")
    {:ok, state}
  end

  @impl true
  def handle_call({:register, policy_id, source, opts}, _from, state) do
    case DSL.parse(source, Keyword.merge(opts, name: policy_id)) do
      {:ok, policy} ->
        case DSL.validate(policy) do
          :ok ->
            {version, new_state} = add_policy_version(state, policy_id, policy)
            Logger.info("Policy registered: #{policy_id} v#{version}")
            {:reply, {:ok, version}, new_state}

          {:error, reason} ->
            {:reply, {:error, {:validation_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:register_rules, policy_id, rules, opts}, _from, state) do
    case DSL.from_rules(rules, Keyword.merge(opts, name: policy_id)) do
      {:ok, policy} ->
        case DSL.validate(policy) do
          :ok ->
            {version, new_state} = add_policy_version(state, policy_id, policy)
            Logger.info("Policy registered from rules: #{policy_id} v#{version}")
            {:reply, {:ok, version}, new_state}

          {:error, reason} ->
            {:reply, {:error, {:validation_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:evaluate, policy_id, eval_context, opts}, _from, state) do
    start_time = System.monotonic_time(:microsecond)

    result =
      case get_policy(state, policy_id) do
        {:ok, policy} ->
          Runtime.evaluate(policy, eval_context, opts)

        {:error, _} = error ->
          error
      end

    elapsed_us = System.monotonic_time(:microsecond) - start_time
    new_state = update_stats(state, result, elapsed_us)

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:evaluate_all, policy_ids, eval_context, opts}, _from, state) do
    start_time = System.monotonic_time(:microsecond)

    policies =
      Enum.reduce_while(policy_ids, [], fn policy_id, acc ->
        case get_policy(state, policy_id) do
          {:ok, policy} -> {:cont, [policy | acc]}
          {:error, _} = error -> {:halt, error}
        end
      end)

    result =
      case policies do
        {:error, _} = error -> error
        policies when is_list(policies) -> Runtime.evaluate_all(Enum.reverse(policies), eval_context, opts)
      end

    elapsed_us = System.monotonic_time(:microsecond) - start_time
    new_state = update_stats(state, result, elapsed_us)

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:get_active_version, policy_id}, _from, state) do
    result =
      case Map.get(state.active_versions, policy_id) do
        nil -> {:error, :not_found}
        version -> {:ok, version}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_active_version, policy_id, version}, _from, state) do
    versions = Map.get(state.policies, policy_id, %{})

    if Map.has_key?(versions, version) do
      new_state = %{state | active_versions: Map.put(state.active_versions, policy_id, version)}
      Logger.info("Policy #{policy_id} active version set to v#{version}")
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :version_not_found}, state}
    end
  end

  @impl true
  def handle_call({:list_versions, policy_id}, _from, state) do
    versions =
      state.policies
      |> Map.get(policy_id, %{})
      |> Map.keys()
      |> Enum.sort()

    {:reply, versions, state}
  end

  @impl true
  def handle_call({:delete, policy_id}, _from, state) do
    new_state = %{
      state
      | policies: Map.delete(state.policies, policy_id),
        active_versions: Map.delete(state.active_versions, policy_id)
    }

    Logger.info("Policy deleted: #{policy_id}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        policy_count: map_size(state.policies),
        wasm_available: Runtime.wasm_available?()
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:list_policies, _from, state) do
    {:reply, Map.keys(state.policies), state}
  end

  # Private helpers

  defp add_policy_version(state, policy_id, policy) do
    versions = Map.get(state.policies, policy_id, %{})
    next_version = if map_size(versions) == 0, do: 1, else: Enum.max(Map.keys(versions)) + 1

    policy_with_version = %{policy | version: next_version}

    new_policies =
      Map.update(state.policies, policy_id, %{next_version => policy_with_version}, fn versions ->
        Map.put(versions, next_version, policy_with_version)
      end)

    new_active_versions = Map.put(state.active_versions, policy_id, next_version)

    new_state = %{state | policies: new_policies, active_versions: new_active_versions}

    {next_version, new_state}
  end

  defp get_policy(state, policy_id) do
    case Map.get(state.active_versions, policy_id) do
      nil ->
        {:error, :policy_not_found}

      version ->
        case get_in(state.policies, [policy_id, version]) do
          nil -> {:error, :version_not_found}
          policy -> {:ok, policy}
        end
    end
  end

  defp update_stats(state, result, elapsed_us) do
    stats = state.stats

    new_stats =
      case result do
        :allow ->
          %{stats | evaluations: stats.evaluations + 1, allows: stats.allows + 1}

        :deny ->
          %{stats | evaluations: stats.evaluations + 1, denies: stats.denies + 1}

        {:error, _} ->
          %{stats | evaluations: stats.evaluations + 1, errors: stats.errors + 1}
      end

    # Update running average
    n = new_stats.evaluations
    old_avg = stats.avg_eval_time_us

    new_avg =
      if n == 1 do
        elapsed_us * 1.0
      else
        old_avg + (elapsed_us - old_avg) / n
      end

    new_stats = %{new_stats | avg_eval_time_us: new_avg}

    %{state | stats: new_stats}
  end
end
