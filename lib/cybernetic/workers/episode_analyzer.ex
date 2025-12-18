defmodule Cybernetic.Workers.EpisodeAnalyzer do
  @moduledoc """
  Oban worker for analyzing episodes using LLM-based analysis.

  Processes episode content to extract:
  - Key topics and themes
  - Entity mentions
  - Sentiment analysis
  - Action items
  - Summary generation

  ## Configuration

      config :cybernetic, Oban,
        queues: [analysis: 5]

  ## Job Arguments

      %{
        episode_id: "uuid",
        tenant_id: "tenant-1",
        analysis_type: "full" | "summary" | "entities",
        options: %{}
      }
  """
  use Oban.Worker,
    queue: :analysis,
    max_attempts: 3,
    priority: 2

  require Logger

  @telemetry [:cybernetic, :worker, :episode_analyzer]

  @type analysis_type :: :full | :summary | :entities | :sentiment
  @type job_args :: %{
          episode_id: String.t(),
          tenant_id: String.t(),
          analysis_type: String.t(),
          options: map()
        }

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()} | {:snooze, pos_integer()}
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    episode_id = args["episode_id"]
    tenant_id = args["tenant_id"]
    analysis_type = String.to_existing_atom(args["analysis_type"] || "full")
    options = args["options"] || %{}

    Logger.info("Starting episode analysis",
      episode_id: episode_id,
      tenant_id: tenant_id,
      analysis_type: analysis_type,
      attempt: attempt
    )

    start_time = System.monotonic_time(:millisecond)

    result =
      with {:ok, episode} <- fetch_episode(tenant_id, episode_id),
           {:ok, analysis} <- analyze_episode(episode, analysis_type, options),
           :ok <- store_analysis(tenant_id, episode_id, analysis) do
        emit_telemetry(:success, start_time, analysis_type)
        publish_analysis_complete(tenant_id, episode_id, analysis)
        :ok
      else
        {:error, :not_found} ->
          Logger.warning("Episode not found",
            episode_id: episode_id,
            tenant_id: tenant_id
          )

          emit_telemetry(:not_found, start_time, analysis_type)
          {:error, :not_found}

        {:error, :rate_limited} ->
          # Snooze and retry later
          Logger.info("Rate limited, snoozing", episode_id: episode_id)
          emit_telemetry(:rate_limited, start_time, analysis_type)
          {:snooze, 60}

        {:error, reason} ->
          Logger.error("Episode analysis failed",
            episode_id: episode_id,
            reason: reason
          )

          emit_telemetry(:error, start_time, analysis_type)
          {:error, reason}
      end

    result
  end

  # Fetch episode from storage

  @spec fetch_episode(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp fetch_episode(tenant_id, episode_id) do
    # Try to get episode from EpisodeStore or database
    case get_episode_from_store(tenant_id, episode_id) do
      {:ok, episode} ->
        {:ok, episode}

      {:error, :not_found} ->
        # Try storage as fallback
        path = "episodes/#{episode_id}/content.json"

        case Cybernetic.Storage.get(tenant_id, path) do
          {:ok, content} ->
            {:ok, Jason.decode!(content)}

          error ->
            error
        end
    end
  end

  defp get_episode_from_store(tenant_id, episode_id) do
    # Placeholder - would query EpisodeStore GenServer
    # For now, return not_found to trigger storage fallback
    {:error, :not_found}
  end

  # Analyze episode content

  @spec analyze_episode(map(), analysis_type(), map()) :: {:ok, map()} | {:error, term()}
  defp analyze_episode(episode, :full, options) do
    # Full analysis includes all components
    with {:ok, summary} <- generate_summary(episode, options),
         {:ok, entities} <- extract_entities(episode, options),
         {:ok, sentiment} <- analyze_sentiment(episode, options),
         {:ok, topics} <- extract_topics(episode, options) do
      analysis = %{
        type: :full,
        summary: summary,
        entities: entities,
        sentiment: sentiment,
        topics: topics,
        analyzed_at: DateTime.utc_now(),
        model: get_model_info()
      }

      {:ok, analysis}
    end
  end

  defp analyze_episode(episode, :summary, options) do
    with {:ok, summary} <- generate_summary(episode, options) do
      {:ok, %{type: :summary, summary: summary, analyzed_at: DateTime.utc_now()}}
    end
  end

  defp analyze_episode(episode, :entities, options) do
    with {:ok, entities} <- extract_entities(episode, options) do
      {:ok, %{type: :entities, entities: entities, analyzed_at: DateTime.utc_now()}}
    end
  end

  defp analyze_episode(episode, :sentiment, options) do
    with {:ok, sentiment} <- analyze_sentiment(episode, options) do
      {:ok, %{type: :sentiment, sentiment: sentiment, analyzed_at: DateTime.utc_now()}}
    end
  end

  # LLM-based analysis functions

  @spec generate_summary(map(), map()) :: {:ok, String.t()} | {:error, term()}
  defp generate_summary(episode, _options) do
    content = episode["content"] || episode["text"] || ""

    if String.length(content) < 100 do
      {:ok, content}
    else
      # Use ReqLLM for summary generation (per constitution)
      prompt = """
      Summarize the following content in 2-3 sentences:

      #{content}
      """

      case call_llm(prompt) do
        {:ok, summary} -> {:ok, summary}
        error -> error
      end
    end
  end

  @spec extract_entities(map(), map()) :: {:ok, [map()]} | {:error, term()}
  defp extract_entities(episode, _options) do
    content = episode["content"] || episode["text"] || ""

    prompt = """
    Extract named entities from the following content. Return as JSON array with objects containing:
    - name: entity name
    - type: person, organization, location, product, event, or other
    - mentions: number of times mentioned

    Content:
    #{content}
    """

    case call_llm(prompt) do
      {:ok, response} ->
        entities = parse_json_response(response, [])
        {:ok, entities}

      error ->
        error
    end
  end

  @spec analyze_sentiment(map(), map()) :: {:ok, map()} | {:error, term()}
  defp analyze_sentiment(episode, _options) do
    content = episode["content"] || episode["text"] || ""

    prompt = """
    Analyze the sentiment of the following content. Return as JSON with:
    - overall: positive, negative, neutral, or mixed
    - confidence: 0.0 to 1.0
    - aspects: array of {aspect, sentiment, confidence}

    Content:
    #{content}
    """

    case call_llm(prompt) do
      {:ok, response} ->
        sentiment =
          parse_json_response(response, %{
            "overall" => "neutral",
            "confidence" => 0.5,
            "aspects" => []
          })

        {:ok, sentiment}

      error ->
        error
    end
  end

  @spec extract_topics(map(), map()) :: {:ok, [String.t()]} | {:error, term()}
  defp extract_topics(episode, _options) do
    content = episode["content"] || episode["text"] || ""

    prompt = """
    Extract the main topics from the following content. Return as JSON array of strings.
    List 3-5 main topics.

    Content:
    #{content}
    """

    case call_llm(prompt) do
      {:ok, response} ->
        topics = parse_json_response(response, [])
        {:ok, topics}

      error ->
        error
    end
  end

  # LLM API call (uses ReqLLM per constitution)

  @spec call_llm(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp call_llm(prompt) do
    # Check if ReqLLM is available
    if Code.ensure_loaded?(ReqLLM) do
      config = get_llm_config()

      req =
        Req.new(base_url: config[:base_url])
        |> ReqLLM.attach()

      case Req.post(req,
             json: %{
               model: config[:model],
               messages: [%{role: "user", content: prompt}],
               max_tokens: 1000
             }
           ) do
        {:ok, %{body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
          {:ok, content}

        {:ok, %{status: 429}} ->
          {:error, :rate_limited}

        {:error, reason} ->
          {:error, reason}
      end
    else
      # Fallback: return placeholder
      Logger.warning("ReqLLM not available, using placeholder analysis")
      {:ok, "[Analysis placeholder - ReqLLM not configured]"}
    end
  rescue
    e ->
      Logger.error("LLM call failed", error: inspect(e))
      {:error, :llm_error}
  end

  defp get_llm_config do
    Application.get_env(:cybernetic, :llm, [])
    |> Keyword.merge(
      base_url: "https://api.openai.com/v1",
      model: "gpt-4o-mini"
    )
  end

  defp get_model_info do
    config = get_llm_config()
    %{provider: "openai", model: config[:model]}
  end

  # Store analysis results

  @spec store_analysis(String.t(), String.t(), map()) :: :ok | {:error, term()}
  defp store_analysis(tenant_id, episode_id, analysis) do
    path = "episodes/#{episode_id}/analysis.json"
    content = Jason.encode!(analysis)

    case Cybernetic.Storage.put(tenant_id, path, content, content_type: "application/json") do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Publish completion event

  defp publish_analysis_complete(tenant_id, episode_id, analysis) do
    Phoenix.PubSub.broadcast(
      Cybernetic.PubSub,
      "events:episode",
      {:event, "episode.analyzed", %{
        tenant_id: tenant_id,
        episode_id: episode_id,
        analysis_type: analysis.type,
        timestamp: DateTime.utc_now()
      }}
    )
  end

  # Parse JSON from LLM response

  defp parse_json_response(response, default) do
    # Try to extract JSON from response
    json_pattern = ~r/\[[\s\S]*\]|\{[\s\S]*\}/

    case Regex.run(json_pattern, response) do
      [json_str | _] ->
        case Jason.decode(json_str) do
          {:ok, parsed} -> parsed
          _ -> default
        end

      nil ->
        default
    end
  end

  # Telemetry

  defp emit_telemetry(status, start_time, analysis_type) do
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      @telemetry,
      %{duration: duration, count: 1},
      %{status: status, analysis_type: analysis_type}
    )
  end
end
