defmodule Cybernetic.VSM.System4.Service do
  @moduledoc """
  S4 Intelligence Service - Multi-provider AI coordination for the VSM framework.
  
  Provides the main public API for S4 intelligence operations with intelligent
  routing, fallback handling, and circuit breaking across multiple LLM providers.
  """
  
  use GenServer
  require Logger
  require OpenTelemetry.Tracer
  
  alias Cybernetic.VSM.System4.{Episode, Router}
  
  @telemetry [:cybernetic, :s4, :service]

  defstruct [
    :providers,
    :circuit_breakers,
    :stats,
    :config
  ]

  @type t :: %__MODULE__{
    providers: map(),
    circuit_breakers: map(),
    stats: map(),
    config: map()
  }

  # Public API

  @doc """
  Start the S4 Service.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Analyze an episode using the best available provider chain.
  
  ## Parameters
  
  - episode: Episode struct or episode data
  - opts: Analysis options
  
  ## Returns
  
  {:ok, result, metadata} | {:error, reason}
  """
  def analyze(episode_or_data, opts \\ [])

  def analyze(%Episode{} = episode, opts) do
    GenServer.call(__MODULE__, {:analyze, episode, opts}, 60_000)
  end

  def analyze(episode_data, opts) when is_map(episode_data) do
    episode = convert_to_episode(episode_data)
    analyze(episode, opts)
  end

  @doc """
  Generate text completion using the best available provider.
  
  ## Parameters
  
  - prompt: String prompt or message list
  - opts: Generation options
  
  ## Returns
  
  {:ok, result, metadata} | {:error, reason}
  """
  def complete(prompt, opts \\ []) do
    GenServer.call(__MODULE__, {:complete, prompt, opts}, 60_000)
  end

  @doc """
  Generate embeddings for text.
  
  ## Parameters
  
  - text: Input text
  - opts: Embedding options
  
  ## Returns
  
  {:ok, result, metadata} | {:error, reason}
  """
  def embed(text, opts \\ []) do
    GenServer.call(__MODULE__, {:embed, text, opts}, 30_000)
  end

  @doc """
  Get service health status.
  """
  def health_status do
    GenServer.call(__MODULE__, :health_status, 5_000)
  end

  @doc """
  Get service statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats, 5_000)
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    config = load_config(opts)
    
    state = %__MODULE__{
      providers: %{},
      circuit_breakers: initialize_circuit_breakers(),
      stats: initialize_stats(),
      config: config
    }
    
    Logger.info("S4 Service initialized with providers: #{inspect(Map.keys(state.circuit_breakers))}")
    
    # Schedule periodic health checks
    schedule_health_check()
    
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:analyze, episode, opts}, _from, state) do
    start_time = System.monotonic_time(:millisecond)
    
    result = OpenTelemetry.Tracer.with_span "s4.service.analyze", %{
      attributes: %{
        episode_id: episode.id,
        episode_kind: episode.kind,
        priority: episode.priority
      }
    } do
      do_analyze(episode, opts, state)
    end
    
    latency = System.monotonic_time(:millisecond) - start_time
    new_state = update_stats(state, :analyze, result, latency)
    
    {:reply, result, new_state}
  end

  @impl GenServer
  def handle_call({:complete, prompt, opts}, _from, state) do
    start_time = System.monotonic_time(:millisecond)
    
    result = OpenTelemetry.Tracer.with_span "s4.service.complete", %{
      attributes: %{
        prompt_length: byte_size(to_string(prompt))
      }
    } do
      do_complete(prompt, opts, state)
    end
    
    latency = System.monotonic_time(:millisecond) - start_time
    new_state = update_stats(state, :complete, result, latency)
    
    {:reply, result, new_state}
  end

  @impl GenServer
  def handle_call({:embed, text, opts}, _from, state) do
    start_time = System.monotonic_time(:millisecond)
    
    result = OpenTelemetry.Tracer.with_span "s4.service.embed", %{
      attributes: %{
        text_length: byte_size(text)
      }
    } do
      do_embed(text, opts, state)
    end
    
    latency = System.monotonic_time(:millisecond) - start_time
    new_state = update_stats(state, :embed, result, latency)
    
    {:reply, result, new_state}
  end

  @impl GenServer
  def handle_call(:health_status, _from, state) do
    health = check_provider_health(state)
    {:reply, health, state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl GenServer
  def handle_info(:health_check, state) do
    new_state = perform_health_check(state)
    schedule_health_check()
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp do_analyze(episode, opts, state) do
    case check_s3_budget(:s4_llm, episode) do
      :ok ->
        Router.route(episode, opts)
        
      {:error, :budget_exhausted} ->
        emit_budget_deny_telemetry(episode)
        {:error, :rate_limited}
    end
  end

  defp do_complete(prompt, opts, _state) do
    # For completion, use a simple episode for routing
    episode = Episode.new(:code_gen, "Text completion", prompt, 
      priority: Keyword.get(opts, :priority, :normal)
    )
    
    case Router.route(episode, Keyword.put(opts, :operation, :complete)) do
      {:ok, result, metadata} ->
        # Extract just the text completion part
        completion_result = %{
          text: result.text,
          tokens: result.tokens,
          usage: result.usage,
          finish_reason: Map.get(result, :finish_reason, :stop)
        }
        {:ok, completion_result, metadata}
        
      error ->
        error
    end
  end

  defp do_embed(text, opts, _state) do
    # For embeddings, try providers that support it
    providers_with_embeddings = [:openai, :ollama]
    
    case try_embedding_providers(text, opts, providers_with_embeddings) do
      {:ok, result, provider} ->
        {:ok, result, %{provider: provider}}
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_embedding_providers(_text, _opts, []) do
    {:error, :no_embedding_providers_available}
  end

  defp try_embedding_providers(text, opts, [provider | rest]) do
    case Router.get_provider_module(provider) do
      {:ok, module} ->
        case module.embed(text, opts) do
          {:ok, result} ->
            {:ok, result, provider}
            
          {:error, :embeddings_not_supported} ->
            try_embedding_providers(text, opts, rest)
            
          {:error, _reason} ->
            try_embedding_providers(text, opts, rest)
        end
        
      {:error, _} ->
        try_embedding_providers(text, opts, rest)
    end
  end

  defp convert_to_episode(episode_data) do
    Episode.new(
      Map.get(episode_data, :kind, :classification),
      Map.get(episode_data, :title, "Unnamed Episode"),
      Map.get(episode_data, :data, episode_data),
      context: Map.get(episode_data, :context, %{}),
      metadata: Map.get(episode_data, :metadata, %{}),
      priority: Map.get(episode_data, :priority, :normal),
      source_system: Map.get(episode_data, :source_system, :unknown)
    )
  end

  defp check_s3_budget(budget_type, episode) do
    try do
      case Cybernetic.VSM.System3.RateLimiter.request_tokens(budget_type, episode.kind, episode.priority) do
        :ok -> :ok
        {:error, :rate_limited} -> {:error, :budget_exhausted}
      end
    rescue
      _ -> :ok  # Fallback if RateLimiter not available
    end
  end

  defp load_config(opts) do
    default_config = %{
      health_check_interval: 60_000,  # 1 minute
      circuit_breaker_threshold: 5,
      circuit_breaker_timeout: 30_000
    }
    
    app_config = Application.get_env(:cybernetic, :s4, [])
    |> Enum.into(%{})
    
    opts_config = Keyword.take(opts, [:health_check_interval, :circuit_breaker_threshold])
    |> Enum.into(%{})
    
    Map.merge(default_config, Map.merge(app_config, opts_config))
  end

  defp initialize_circuit_breakers do
    providers = [:anthropic, :openai, :ollama]
    
    Enum.into(providers, %{}, fn provider ->
      {provider, %{
        state: :closed,
        failure_count: 0,
        last_failure_time: nil,
        last_success_time: System.monotonic_time(:millisecond)
      }}
    end)
  end

  defp initialize_stats do
    %{
      requests: %{
        analyze: %{total: 0, success: 0, error: 0},
        complete: %{total: 0, success: 0, error: 0},
        embed: %{total: 0, success: 0, error: 0}
      },
      latency: %{
        analyze: %{total: 0, count: 0, avg: 0},
        complete: %{total: 0, count: 0, avg: 0},
        embed: %{total: 0, count: 0, avg: 0}
      },
      providers: %{
        anthropic: %{requests: 0, success: 0, error: 0},
        openai: %{requests: 0, success: 0, error: 0},
        ollama: %{requests: 0, success: 0, error: 0}
      }
    }
  end

  defp update_stats(state, operation, result, latency) do
    stats = state.stats
    
    # Update request stats
    req_stats = get_in(stats, [:requests, operation])
    new_req_stats = %{
      total: req_stats.total + 1,
      success: req_stats.success + (if match?({:ok, _, _}, result), do: 1, else: 0),
      error: req_stats.error + (if match?({:error, _}, result), do: 1, else: 0)
    }
    
    # Update latency stats
    lat_stats = get_in(stats, [:latency, operation])
    new_total = lat_stats.total + latency
    new_count = lat_stats.count + 1
    new_lat_stats = %{
      total: new_total,
      count: new_count,
      avg: div(new_total, new_count)
    }
    
    new_stats = stats
    |> put_in([:requests, operation], new_req_stats)
    |> put_in([:latency, operation], new_lat_stats)
    
    %{state | stats: new_stats}
  end

  defp check_provider_health(state) do
    state.circuit_breakers
    |> Enum.map(fn {provider, cb_state} ->
      health = case cb_state.state do
        :closed -> :healthy
        :open -> :unhealthy
        :half_open -> :recovering
      end
      
      {provider, %{
        health: health,
        last_success: cb_state.last_success_time,
        failure_count: cb_state.failure_count
      }}
    end)
    |> Enum.into(%{})
  end

  defp perform_health_check(state) do
    # This would check each provider's health
    # For now, we'll just return the current state
    state
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, 60_000)
  end

  defp emit_budget_deny_telemetry(episode) do
    :telemetry.execute(
      [:cyb, :s3, :budget, :deny],
      %{},
      %{
        service: :s4,
        episode_id: episode.id,
        episode_kind: episode.kind,
        reason: :s4_budget_exhausted
      }
    )
  end
end