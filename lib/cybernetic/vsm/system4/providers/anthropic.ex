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
  def analyze_episode(provider, episode, context_opts \\ []) do
    OTEL.with_span "anthropic.analyze_episode", %{
      model: provider.model,
      episode_id: episode["id"],
      episode_type: episode["type"]
    } do
      do_analyze_episode(provider, episode, context_opts)
    end
  end
  
  defp do_analyze_episode(provider, episode, context_opts) do
    :telemetry.execute(@telemetry ++ [:request], %{count: 1}, %{
      model: provider.model,
      episode_type: episode["type"]
    })
    
    prompt = build_analysis_prompt(episode, context_opts)
    
    case make_anthropic_request(provider, prompt) do
      {:ok, response} ->
        :telemetry.execute(@telemetry ++ [:response], %{
          count: 1,
          tokens: response["usage"]["output_tokens"]
        }, %{model: provider.model})
        
        parse_analysis_response(response)
        
      {:error, reason} = error ->
        :telemetry.execute(@telemetry ++ [:error], %{count: 1}, %{
          reason: inspect(reason),
          model: provider.model
        })
        error
    end
  end
  
  defp build_analysis_prompt(episode, context_opts) do
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
    
    ID: #{episode["id"]}
    Type: #{episode["type"]}
    Severity: #{episode["severity"]}
    Timestamp: #{episode["timestamp"]}
    
    Details:
    #{Jason.encode!(episode, pretty: true)}
    
    Context:
    #{if context_opts != [], do: Jason.encode!(context_opts, pretty: true), else: "No additional context"}
    
    Please analyze this episode and provide structured recommendations.
    """
    
    %{
      "model" => provider.model,
      "max_tokens" => provider.max_tokens,
      "temperature" => provider.temperature,
      "system" => system_prompt,
      "messages" => [
        %{
          "role" => "user",
          "content" => user_prompt
        }
      ]
    }
  end
  
  defp make_anthropic_request(provider, payload) do
    url = "#{provider.base_url}/v1/messages"
    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{provider.api_key}"},
      {"anthropic-version", "2023-06-01"}
    ]
    
    with {:ok, json} <- Jason.encode(payload),
         {:ok, %{status: 200, body: body}} <- 
           HTTPoison.post(url, json, headers, timeout: provider.timeout),
         {:ok, response} <- Jason.decode(body) do
      {:ok, response}
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error: #{status} - #{body}")
        {:error, {:http_error, status, body}}
        
      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, {:network_error, reason}}
        
      {:error, reason} ->
        Logger.error("JSON encoding/decoding failed: #{inspect(reason)}")
        {:error, {:json_error, reason}}
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