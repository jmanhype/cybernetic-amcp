defmodule Cybernetic.VSM.System4.Providers.Anthropic do
  @moduledoc """
  Anthropic Claude provider for S4 Intelligence system.
  
  Implements the LLM provider behavior for episode analysis using Claude's
  reasoning capabilities for VSM decision-making and SOP recommendations.
  """
  
  @behaviour Cybernetic.VSM.System4.LLMProvider
  
  require Logger
  alias Cybernetic.Telemetry.OTEL
  
  @default_model "claude-3-5-sonnet-20241022"
  @default_max_tokens 4096
  @default_temperature 0.1
  @telemetry [:cybernetic, :s4, :anthropic]
  
  defstruct [
    :api_key,
    :model,
    :max_tokens,
    :temperature,
    :base_url,
    :timeout
  ]
  
  @type t :: %__MODULE__{
    api_key: String.t(),
    model: String.t(),
    max_tokens: pos_integer(),
    temperature: float(),
    base_url: String.t(),
    timeout: pos_integer()
  }
  
  @doc """
  Creates a new Anthropic provider instance.
  
  ## Options
  - `:api_key` - Anthropic API key (required)
  - `:model` - Claude model to use (default: claude-3-5-sonnet-20241022)
  - `:max_tokens` - Maximum response tokens (default: 4096)
  - `:temperature` - Sampling temperature (default: 0.1)
  - `:base_url` - API base URL (default: https://api.anthropic.com)
  - `:timeout` - Request timeout in ms (default: 30000)
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")
    
    unless api_key do
      {:error, :missing_api_key}
    else
      provider = %__MODULE__{
        api_key: api_key,
        model: Keyword.get(opts, :model, @default_model),
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
        temperature: Keyword.get(opts, :temperature, @default_temperature),
        base_url: Keyword.get(opts, :base_url, "https://api.anthropic.com"),
        timeout: Keyword.get(opts, :timeout, 30_000)
      }
      
      {:ok, provider}
    end
  end
  
  @impl Cybernetic.VSM.System4.LLMProvider
  def capabilities do
    %{
      modes: [:chat, :tool_use, :json, :reasoning],
      strengths: [:reasoning, :code],
      max_tokens: 8192,
      context_window: 200_000
    }
  end

  @impl Cybernetic.VSM.System4.LLMProvider
  def analyze_episode(episode, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    
    OpenTelemetry.Tracer.with_span "anthropic.analyze_episode", %{
      attributes: %{
        model: get_model(opts),
        episode_id: episode.id,
        episode_kind: episode.kind
      }
    } do
      result = do_analyze_episode(episode, opts)
      
      latency = System.monotonic_time(:millisecond) - start_time
      add_usage_metrics(result, latency)
      
      result
    end
  end

  @impl Cybernetic.VSM.System4.LLMProvider
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    generate([%{"role" => "user", "content" => prompt}], opts)
  end

  def generate(messages, opts \\ []) when is_list(messages) do
    start_time = System.monotonic_time(:millisecond)
    
    case make_anthropic_request(build_generate_payload(messages, opts)) do
      {:ok, response} ->
        latency = System.monotonic_time(:millisecond) - start_time
        parse_generate_response(response, latency)
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Cybernetic.VSM.System4.LLMProvider
  def embed(text, _opts \\ []) do
    # Anthropic doesn't provide embeddings - return error
    {:error, :embeddings_not_supported}
  end

  @impl Cybernetic.VSM.System4.LLMProvider
  def health_check do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> {:error, :missing_api_key}
      _key -> 
        # Simple ping test
        case make_anthropic_request(%{
          "model" => @default_model,
          "max_tokens" => 1,
          "messages" => [%{"role" => "user", "content" => "test"}]
        }) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
  
  defp do_analyze_episode(episode, opts) do
    model = get_model(opts)
    
    :telemetry.execute(@telemetry ++ [:request], %{count: 1}, %{
      model: model,
      episode_kind: episode.kind
    })
    
    prompt = build_analysis_prompt(episode, opts)
    
    case make_anthropic_request(prompt) do
      {:ok, response} ->
        :telemetry.execute(@telemetry ++ [:response], %{
          count: 1,
          tokens: get_in(response, ["usage", "output_tokens"]) || 0
        }, %{model: model})
        
        parse_analysis_response(response)
        
      {:error, reason} = error ->
        :telemetry.execute(@telemetry ++ [:error], %{count: 1}, %{
          reason: inspect(reason),
          model: model
        })
        error
    end
  end
  
  defp build_analysis_prompt(episode, opts) do
    system_prompt = """
    You are the S4 Intelligence system in a Viable System Model (VSM) framework.
    Your role is to analyze operational episodes and provide strategic recommendations.
    
    Analyze the given episode and provide:
    1. Root cause analysis using systems thinking
    2. Specific SOP (Standard Operating Procedure) recommendations
    3. Risk assessment and mitigation strategies
    4. Learning opportunities for the organization
    
    Respond in JSON format with the following structure:
    {
      "summary": "Brief analysis summary",
      "root_causes": ["cause1", "cause2"],
      "sop_suggestions": [
        {
          "title": "SOP Title", 
          "category": "operational|coordination|control|intelligence|policy",
          "priority": "high|medium|low",
          "description": "Detailed SOP description",
          "triggers": ["when to apply this SOP"],
          "actions": ["step1", "step2"]
        }
      ],
      "recommendations": [
        {
          "type": "immediate|short_term|long_term",
          "action": "Specific recommendation",
          "rationale": "Why this is important",
          "system": "s1|s2|s3|s4|s5"
        }
      ],
      "risk_level": "low|medium|high|critical",
      "learning_points": ["key insight 1", "key insight 2"]
    }
    """
    
    user_prompt = """
    Episode to analyze:
    
    ID: #{episode.id}
    Kind: #{episode.kind}
    Title: #{episode.title}
    Priority: #{episode.priority}
    Source: #{episode.source_system}
    Created: #{episode.created_at}
    
    Context:
    #{Jason.encode!(episode.context, pretty: true)}
    
    Data:
    #{format_episode_data(episode.data)}
    
    Metadata:
    #{Jason.encode!(episode.metadata, pretty: true)}
    
    Please analyze this episode and provide structured recommendations.
    """
    
    %{
      "model" => get_model(opts),
      "max_tokens" => get_max_tokens(opts),
      "temperature" => get_temperature(opts),
      "system" => system_prompt,
      "messages" => [
        %{
          "role" => "user",
          "content" => user_prompt
        }
      ]
    }
  end

  defp build_generate_payload(messages, opts) do
    %{
      "model" => get_model(opts),
      "max_tokens" => get_max_tokens(opts),
      "temperature" => get_temperature(opts),
      "messages" => messages
    }
  end

  defp get_model(opts), do: Keyword.get(opts, :model, @default_model)
  defp get_max_tokens(opts), do: Keyword.get(opts, :max_tokens, @default_max_tokens)
  defp get_temperature(opts), do: Keyword.get(opts, :temperature, @default_temperature)
  defp get_api_key, do: System.get_env("ANTHROPIC_API_KEY")
  defp get_base_url, do: "https://api.anthropic.com"

  defp format_episode_data(data) when is_binary(data), do: data
  defp format_episode_data(data), do: Jason.encode!(data, pretty: true)

  defp add_usage_metrics({:ok, result}, latency) do
    case result do
      %{tokens: %{input: input, output: output}} ->
        result = Map.update!(result, :usage, fn usage ->
          Map.merge(usage, %{latency_ms: latency})
        end)
        {:ok, result}
      _ ->
        {:ok, result}
    end
  end

  defp add_usage_metrics(error, _latency), do: error
  
  defp make_anthropic_request(provider, payload) do
    url = "#{provider.base_url}/v1/messages"
    headers = [
      {"Content-Type", "application/json"},
      {"x-api-key", provider.api_key},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta", "max-tokens-3-5-sonnet-2024-07-15"}
    ]
    
    options = [
      timeout: provider.timeout,
      recv_timeout: provider.timeout,
      hackney: [pool: :anthropic_pool]
    ]
    
    with {:ok, json} <- Jason.encode(payload),
         {:ok, response} <- make_request_with_retry(url, json, headers, options, 3) do
      {:ok, response}
    else
      {:error, reason} ->
        Logger.error("Anthropic API request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp make_request_with_retry(url, json, headers, options, retries_left) when retries_left > 0 do
    case HTTPoison.post(url, json, headers, options) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, {:json_decode_error, reason}}
        end
        
      {:ok, %{status: 429} = response} ->
        Logger.warning("Rate limited by Anthropic API, retrying in #{get_retry_delay(response)} ms")
        :timer.sleep(get_retry_delay(response))
        make_request_with_retry(url, json, headers, options, retries_left - 1)
        
      {:ok, %{status: status, body: _body}} when status >= 500 ->
        Logger.warning("Server error #{status}, retrying... (#{retries_left} retries left)")
        :timer.sleep(exponential_backoff(4 - retries_left))
        make_request_with_retry(url, json, headers, options, retries_left - 1)
        
      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error: #{status} - #{body}")
        {:error, {:http_error, status, parse_error_body(body)}}
        
      {:error, %HTTPoison.Error{reason: :timeout}} ->
        Logger.warning("Request timeout, retrying... (#{retries_left} retries left)")
        make_request_with_retry(url, json, headers, options, retries_left - 1)
        
      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, {:network_error, reason}}
    end
  end
  
  defp make_request_with_retry(_url, _json, _headers, _options, 0) do
    {:error, :max_retries_exceeded}
  end
  
  defp get_retry_delay(response) do
    case get_header(response.headers, "retry-after") do
      nil -> 1000 # Default 1 second
      retry_after -> 
        case Integer.parse(retry_after) do
          {seconds, ""} -> seconds * 1000
          _ -> 1000
        end
    end
  end
  
  defp get_header(headers, key) do
    headers
    |> Enum.find(fn {k, _v} -> String.downcase(k) == String.downcase(key) end)
    |> case do
      {_k, v} -> v
      nil -> nil
    end
  end
  
  defp exponential_backoff(attempt) do
    base_delay = 1000 # 1 second
    max_delay = 30_000 # 30 seconds
    delay = base_delay * :math.pow(2, attempt)
    min(delay, max_delay) |> round()
  end
  
  defp parse_error_body(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      {:ok, %{"error" => error}} when is_binary(error) -> error
      {:ok, parsed} -> inspect(parsed)
      {:error, _} -> body
    end
  end
  
  defp parse_analysis_response(response) do
    case response do
      %{"content" => [%{"text" => text}]} ->
        case Jason.decode(text) do
          {:ok, parsed} ->
            result = %{
              summary: parsed["summary"],
              root_causes: parsed["root_causes"] || [],
              sop_suggestions: parsed["sop_suggestions"] || [],
              recommendations: parsed["recommendations"] || [],
              risk_level: parsed["risk_level"] || "medium",
              learning_points: parsed["learning_points"] || []
            }
            
            {:ok, result}
            
          {:error, _} ->
            # Fallback for non-JSON responses
            {:ok, %{
              summary: text,
              root_causes: [],
              sop_suggestions: [%{
                "title" => "Manual Review Required",
                "category" => "intelligence",
                "priority" => "medium",
                "description" => "Response requires manual parsing",
                "triggers" => ["non-structured LLM response"],
                "actions" => ["review raw response", "extract insights manually"]
              }],
              recommendations: [],
              risk_level: "medium",
              learning_points: []
            }}
        end
        
      _ ->
        {:error, {:unexpected_response_format, response}}
    end
  end
end