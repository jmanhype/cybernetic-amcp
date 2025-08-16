defmodule Cybernetic.VSM.System4.Service do
  @moduledoc """
  S4 Service - Intelligent routing and coordination for LLM providers.
  Routes episodes to appropriate providers based on task type and availability.
  """
  use GenServer
  require Logger
  
  alias Cybernetic.VSM.System4.{Episode, Memory}
  alias Cybernetic.VSM.System4.Providers.{Anthropic, OpenAI, Together, Ollama, Null}
  alias Cybernetic.Core.Security.RateLimiter
  alias Cybernetic.Transport.CircuitBreaker
  
  @default_timeout 30_000
  @telemetry [:cybernetic, :s4, :service]
  
  # Provider selection rules
  @provider_rules %{
    reasoning: [:anthropic, :openai],
    code_generation: [:anthropic, :openai, :together],
    general: [:together, :ollama, :openai],
    fast: [:together, :ollama],
    quality: [:anthropic, :openai]
  }
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(opts) do
    state = %{
      providers: init_providers(opts),
      circuit_breakers: %{},
      stats: %{
        total_requests: 0,
        successful: 0,
        failed: 0,
        by_provider: %{}
      }
    }
    
    Logger.info("S4 Service initialized with providers: #{inspect(Map.keys(state.providers))}")
    {:ok, state}
  end
  
  # Public API
  
  @doc """
  Route an episode to the appropriate provider based on task type and availability.
  """
  def route_episode(episode_map) when is_map(episode_map) do
    GenServer.call(__MODULE__, {:route_episode, episode_map}, @default_timeout)
  catch
    :exit, {:noproc, _} ->
      # Service not started, use null provider
      {:ok, %{provider: :null, content: "Service not available", episode_id: episode_map[:id]}}
  end
  
  @doc """
  Analyze an episode using intelligent routing.
  """
  def analyze_episode(%Episode{} = episode, opts \\ []) do
    GenServer.call(__MODULE__, {:analyze, episode, opts}, @default_timeout)
  catch
    :exit, {:noproc, _} ->
      # Service not started, use null provider
      {:ok, %{provider: :null, content: "Service not available", episode_id: episode.id}}
  end
  
  @doc """
  Get service statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, {:noproc, _} ->
      %{error: "Service not running"}
  end
  
  @doc """
  Health check for all providers.
  """
  def health_check do
    GenServer.call(__MODULE__, :health_check, 10_000)
  catch
    :exit, {:noproc, _} ->
      %{status: :down, providers: %{}}
  end
  
  # Server Callbacks
  
  @impl true
  def handle_call({:route_episode, episode_map}, _from, state) do
    # Convert map to Episode struct if needed
    {episode, budget} = case episode_map do
      %Episode{} = e -> {e, %{}}
      %{} -> 
        budget = Map.get(episode_map, :budget, %{})
        episode = struct(Episode, Map.delete(episode_map, :budget))
        {episode, budget}
    end
    
    result = route_to_provider(episode, budget, state)
    
    # Update stats
    new_state = update_stats(state, result)
    
    {:reply, result, new_state}
  end
  
  @impl true
  def handle_call({:analyze, episode, opts}, _from, state) do
    result = do_analyze(episode, opts, state)
    new_state = update_stats(state, result)
    {:reply, result, new_state}
  end
  
  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end
  
  @impl true
  def handle_call(:health_check, _from, state) do
    health = Enum.reduce(state.providers, %{}, fn {name, provider}, acc ->
      status = try do
        provider.health_check()
      rescue
        _ -> :error
      end
      Map.put(acc, name, status)
    end)
    
    {:reply, %{status: :up, providers: health}, state}
  end
  
  # Private Functions
  
  defp init_providers(opts) do
    providers = Keyword.get(opts, :providers, [:anthropic, :openai, :together, :ollama])
    
    Enum.reduce(providers, %{}, fn provider, acc ->
      module = case provider do
        :anthropic -> Anthropic
        :openai -> OpenAI
        :together -> Together
        :ollama -> Ollama
        _ -> Null
      end
      
      Map.put(acc, provider, module)
    end)
  end
  
  defp route_to_provider(episode, budget, state) do
    task_type = detect_task_type(episode)
    provider_order = get_provider_order(task_type, state)
    
    # Check rate limits with graceful fallback
    case check_rate_limit(episode.id) do
      :ok ->
        attempt_providers(episode, provider_order, budget, state)
      {:error, :rate_limited} ->
        {:error, "Rate limited for episode #{episode.id}"}
    end
  end
  
  defp check_rate_limit(episode_id) do
    try do
      RateLimiter.check(episode_id, :s4_llm)
    catch
      :exit, {:noproc, _} ->
        # RateLimiter not running, allow request
        :ok
      _ ->
        # Other errors, allow request
        :ok
    end
  end
  
  defp detect_task_type(%Episode{kind: kind}) when not is_nil(kind) do
    # Map episode kinds to task types
    case kind do
      :policy_review -> :reasoning
      :root_cause -> :reasoning
      :code_gen -> :code_generation
      :anomaly_detection -> :reasoning
      :compliance_check -> :reasoning
      :optimization -> :general
      :prediction -> :general
      :classification -> :fast
      _ -> :general
    end
  end
  defp detect_task_type(%Episode{data: data}) when is_binary(data) do
    # Analyze data content to detect task type
    content = String.downcase(data)
    
    cond do
      String.contains?(content, ["reason", "logic", "analyze", "think"]) -> :reasoning
      String.contains?(content, ["code", "function", "implement", "program"]) -> :code_generation
      String.contains?(content, ["quick", "simple", "fast"]) -> :fast
      true -> :general
    end
  end
  defp detect_task_type(_), do: :general
  
  defp get_provider_order(task_type, state) do
    # Get providers for this task type
    candidates = Map.get(@provider_rules, task_type, [:anthropic, :openai, :together, :ollama])
    
    # Filter to available providers and sort by circuit breaker state
    candidates
    |> Enum.filter(fn p -> Map.has_key?(state.providers, p) end)
    |> Enum.sort_by(fn p -> 
      breaker = Map.get(state.circuit_breakers, p, CircuitBreaker.new(to_string(p)))
      case breaker.state do
        :closed -> 0  # Prefer closed (working) breakers
        :half_open -> 1
        :open -> 2
      end
    end)
  end
  
  defp attempt_providers(_episode, [], _budget, _state) do
    {:error, "No providers available"}
  end
  
  defp attempt_providers(episode, [provider | rest], budget, state) do
    module = Map.get(state.providers, provider)
    breaker = Map.get(state.circuit_breakers, provider, CircuitBreaker.new(to_string(provider)))
    
    case CircuitBreaker.call(breaker, fn ->
      # Store context before calling provider
      Memory.store(episode.id, :system, "Routing to #{provider}", %{provider: provider})
      
      # Call the provider
      case module.analyze_episode(episode, budget: budget) do
        {:ok, result} -> 
          {:ok, Map.put(result, :provider, provider)}
        error -> 
          error
      end
    end) do
      {:ok, result, new_breaker} ->
        # Update circuit breaker state
        _new_state = put_in(state.circuit_breakers[provider], new_breaker)
        {:ok, result}
        
      {:error, :circuit_open} ->
        Logger.warning("Circuit breaker open for #{provider}, trying next")
        attempt_providers(episode, rest, budget, state)
        
      {:error, reason} ->
        Logger.warning("Provider #{provider} failed: #{inspect(reason)}, trying next")
        attempt_providers(episode, rest, budget, state)
    end
  end
  
  defp do_analyze(episode, opts, state) do
    # Store the episode in memory
    Memory.store(episode.id, :user, episode.data || "", %{})
    
    # Route to appropriate provider
    route_to_provider(episode, Keyword.get(opts, :budget, %{}), state)
  end
  
  defp update_stats(state, result) do
    stats = state.stats
    
    new_stats = case result do
      {:ok, %{provider: provider}} ->
        %{stats |
          total_requests: stats.total_requests + 1,
          successful: stats.successful + 1,
          by_provider: Map.update(stats.by_provider, provider, 1, &(&1 + 1))
        }
      {:error, _} ->
        %{stats |
          total_requests: stats.total_requests + 1,
          failed: stats.failed + 1
        }
    end
    
    %{state | stats: new_stats}
  end
end