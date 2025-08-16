defmodule Cybernetic.VSM.System4.Router do
  @moduledoc """
  Intelligent routing for S4 LLM providers based on episode type, capabilities,
  and provider health. Implements fallback chains and circuit breaking.
  """

  require Logger
  require OpenTelemetry.Tracer
  alias Cybernetic.VSM.System4.Episode

  @telemetry_prefix [:cyb, :s4, :route]

  @doc """
  Route an episode to the best available provider chain.
  
  ## Parameters
  
  - episode: Episode struct
  - opts: Routing options
  
  ## Returns
  
  {:ok, result, provider_info} | {:error, reason}
  """
  def route(%Episode{} = episode, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    
    OpenTelemetry.Tracer.with_span "s4.route", %{
      attributes: %{
        episode_id: episode.id,
        episode_kind: episode.kind,
        priority: episode.priority
      }
    } do
      chain = select_chain(episode, opts)
      attempts = 0
      
      result = try_chain(episode, chain, opts, attempts)
      
      latency = System.monotonic_time(:millisecond) - start_time
      
      emit_route_telemetry(episode, chain, result, latency, attempts)
      
      result
    end
  end

  @doc """
  Select provider chain based on episode kind and routing policy.
  """
  def select_chain(%Episode{kind: :policy_review}, _opts) do
    [:anthropic, :ollama]
  end

  def select_chain(%Episode{kind: :code_gen}, _opts) do
    [:openai, :together, :anthropic]  # Together has good code models
  end

  def select_chain(%Episode{kind: :root_cause}, _opts) do
    [:anthropic, :together, :openai]  # Together for fast analysis
  end

  def select_chain(%Episode{kind: :anomaly_detection}, _opts) do
    [:together, :anthropic, :ollama]  # Together for rapid detection
  end

  def select_chain(%Episode{kind: :compliance_check}, _opts) do
    [:anthropic, :ollama]
  end

  def select_chain(%Episode{kind: :optimization}, _opts) do
    [:openai, :together, :anthropic]  # Together has optimization models
  end

  def select_chain(%Episode{kind: :prediction}, _opts) do
    [:together, :anthropic, :openai]  # Together for fast predictions
  end

  def select_chain(%Episode{kind: :classification}, _opts) do
    [:together, :openai, :ollama]  # Together is good at classification
  end

  def select_chain(_episode, opts) do
    Keyword.get(opts, :override_chain, default_chain())
  end

  @doc """
  Get default provider chain from configuration.
  """
  def default_chain do
    Application.get_env(:cybernetic, :s4, [])
    |> Keyword.get(:default_chain, [:anthropic])
    |> Enum.map(fn
      {provider, _config} -> provider
      provider when is_atom(provider) -> provider
    end)
  end

  @doc """
  Try provider chain with exponential backoff and circuit breaking.
  """
  def try_chain(_episode, [], _opts, attempts) do
    Logger.error("S4 Router: All providers failed after #{attempts} attempts")
    {:error, :all_providers_failed}
  end

  def try_chain(episode, [provider | rest], opts, attempts) do
    case get_provider_module(provider) do
      {:ok, module} ->
        case try_provider(episode, module, provider, opts, attempts) do
          {:ok, result} ->
            {:ok, result, %{provider: provider, attempts: attempts + 1}}
            
          {:error, reason} when reason in [:rate_limited, :timeout, :invalid_response, :circuit_open] ->
            Logger.warning("S4 Router: Provider #{provider} failed: #{reason}, trying next")
            
            # Exponential backoff with jitter
            backoff_ms = calculate_backoff(attempts)
            Process.sleep(backoff_ms)
            
            emit_fallback_telemetry(episode, provider, reason)
            try_chain(episode, rest, opts, attempts + 1)
            
          {:error, reason} ->
            Logger.error("S4 Router: Provider #{provider} failed permanently: #{reason}")
            {:error, reason}
        end
        
      {:error, reason} ->
        Logger.error("S4 Router: Provider #{provider} not available: #{reason}")
        try_chain(episode, rest, opts, attempts)
    end
  end

  @doc """
  Try a specific provider with circuit breaking and budget checks.
  """
  def try_provider(episode, module, provider, opts, attempts) do
    # Check S3 rate limiter budget before proceeding
    case check_budget(provider, episode) do
      :ok ->
        do_try_provider(episode, module, provider, opts, attempts)
        
      {:error, :budget_exhausted} ->
        emit_budget_deny_telemetry(provider, episode)
        {:error, :rate_limited}
    end
  end

  defp do_try_provider(episode, module, provider, opts, _attempts) do
    start_time = System.monotonic_time(:millisecond)
    
    OpenTelemetry.Tracer.with_span "s4.request", %{
      attributes: %{
        provider: provider,
        episode_id: episode.id,
        episode_kind: episode.kind
      }
    } do
      try do
        provider_opts = get_provider_config(provider, opts)
        result = module.analyze_episode(episode, provider_opts)
        
        latency = System.monotonic_time(:millisecond) - start_time
        emit_provider_telemetry(provider, :success, latency, result)
        
        result
        
      rescue
        exception ->
          latency = System.monotonic_time(:millisecond) - start_time
          emit_provider_telemetry(provider, :error, latency, {:error, exception})
          
          case exception do
            %{status: 429} -> {:error, :rate_limited}
            %{status: 408} -> {:error, :timeout}
            %{status: status} when status >= 500 -> {:error, :server_error}
            _ -> {:error, :request_failed}
          end
      end
    end
  end

  @doc """
  Get provider module for a given provider atom.
  """
  def get_provider_module(:anthropic) do
    {:ok, Cybernetic.VSM.System4.Providers.Anthropic}
  end

  def get_provider_module(:openai) do
    {:ok, Cybernetic.VSM.System4.Providers.OpenAI}
  end

  def get_provider_module(:ollama) do
    {:ok, Cybernetic.VSM.System4.Providers.Ollama}
  end

  def get_provider_module(:together) do
    {:ok, Cybernetic.VSM.System4.Providers.Together}
  end

  def get_provider_module(provider) do
    {:error, {:unknown_provider, provider}}
  end

  @doc """
  Get provider-specific configuration.
  """
  def get_provider_config(provider, opts) do
    base_config = Application.get_env(:cybernetic, provider_config_key(provider), [])
    Keyword.merge(base_config, opts)
  end

  defp provider_config_key(:anthropic), do: Cybernetic.VSM.System4.Providers.Anthropic
  defp provider_config_key(:openai), do: Cybernetic.VSM.System4.Providers.OpenAI
  defp provider_config_key(:ollama), do: Cybernetic.VSM.System4.Providers.Ollama
  defp provider_config_key(:together), do: Cybernetic.VSM.System4.Providers.Together

  @doc """
  Check S3 rate limiter budget for provider.
  """
  def check_budget(provider, episode) do
    # TODO: Integrate with S3 RateLimiter
    # For now, always allow
    case Cybernetic.VSM.System3.RateLimiter.request_tokens(:s4_llm, provider, episode.priority) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :budget_exhausted}
    end
  rescue
    _ -> :ok  # Fallback if RateLimiter not available
  end

  @doc """
  Calculate exponential backoff with jitter.
  """
  def calculate_backoff(attempts) do
    base_delay = 1000  # 1 second base
    max_delay = 30_000  # 30 seconds max
    
    delay = min(base_delay * :math.pow(2, attempts), max_delay)
    jitter = :rand.uniform() * 0.5 * delay
    
    round(delay + jitter)
  end

  # Telemetry emission functions

  defp emit_route_telemetry(episode, chain, result, latency, attempts) do
    measurements = %{latency_ms: latency, attempts: attempts}
    metadata = %{
      episode: %{id: episode.id, kind: episode.kind, priority: episode.priority},
      chain: chain,
      result: format_result(result)
    }
    
    :telemetry.execute(@telemetry_prefix, measurements, metadata)
  end

  defp emit_fallback_telemetry(episode, provider, reason) do
    :telemetry.execute(
      [:cyb, :s4, :fallback],
      %{},
      %{
        episode_id: episode.id,
        provider: provider,
        reason: reason
      }
    )
  end

  defp emit_provider_telemetry(provider, status, latency, result) do
    measurements = %{latency_ms: latency}
    
    measurements = case result do
      {:ok, %{tokens: tokens}} ->
        Map.merge(measurements, %{
          tokens_in: Map.get(tokens, :input, 0),
          tokens_out: Map.get(tokens, :output, 0)
        })
      _ ->
        measurements
    end
    
    metadata = %{provider: provider, status: status}
    
    :telemetry.execute([:cyb, :s4, :provider, :result], measurements, metadata)
  end

  defp emit_budget_deny_telemetry(provider, episode) do
    :telemetry.execute(
      [:cyb, :s3, :budget, :deny],
      %{},
      %{
        provider: provider,
        episode_id: episode.id,
        reason: :s4_llm_budget_exhausted
      }
    )
  end

  defp format_result({:ok, _}), do: :success
  defp format_result({:error, reason}), do: reason
end