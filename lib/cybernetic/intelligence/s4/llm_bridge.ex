defmodule Cybernetic.Intelligence.S4.LLMBridge do
  @moduledoc """
  S4 LLM Bridge - Consumes episodes from the fact bus and produces explanations/remediations.
  
  Implements a strict contract:
  - Input: Episode schema with facts, severity, duration
  - Output: SOP actions with confidence scores
  
  This bridge can connect to various LLM providers (OpenAI, Anthropic, local models).
  """
  use GenServer
  require Logger
  
  @episode_batch_size 5
  @analysis_timeout 30_000
  
  defmodule Episode do
    @moduledoc "Episode input schema"
    defstruct [
      :id,
      :facts,
      :severity,
      :duration_ms,
      :started_at,
      :ended_at,
      :labels,
      :context
    ]
  end
  
  defmodule Explanation do
    @moduledoc "LLM-generated explanation and remediation"
    defstruct [
      :episode_id,
      :summary,
      :root_cause,
      :impact_assessment,
      :recommended_actions,
      :confidence,
      :reasoning,
      :sop_references
    ]
  end
  
  defmodule SOPAction do
    @moduledoc "Actionable SOP instruction"
    defstruct [
      :id,
      :type,  # :automated, :manual, :escalation
      :description,
      :wasm_module,  # Optional WASM module for automated actions
      :parameters,
      :expected_outcome,
      :rollback_plan,
      :confidence
    ]
  end
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(opts) do
    # Subscribe to episode events from aggregator
    :telemetry.attach(
      "s4-llm-bridge-episodes",
      [:cybernetic, :aggregator, :episode],
      &handle_episode_event/4,
      nil
    )
    
    {:ok, %{
      provider: Keyword.get(opts, :provider, :mock),
      api_key: Keyword.get(opts, :api_key),
      model: Keyword.get(opts, :model, "gpt-4"),
      episode_queue: :queue.new(),
      processing: false,
      stats: %{
        episodes_processed: 0,
        explanations_generated: 0,
        actions_proposed: 0,
        errors: 0
      }
    }}
  end
  
  @doc """
  Process an episode and generate explanation with SOP actions.
  """
  def analyze_episode(%Episode{} = episode) do
    GenServer.call(__MODULE__, {:analyze, episode}, @analysis_timeout)
  end
  
  @doc """
  Get current stats.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end
  
  # Callbacks
  
  @impl true
  def handle_call({:analyze, episode}, from, state) do
    # Queue the analysis request
    new_queue = :queue.in({episode, from}, state.episode_queue)
    new_state = %{state | episode_queue: new_queue}
    
    # Start processing if not already running
    if not state.processing do
      send(self(), :process_queue)
      {:noreply, %{new_state | processing: true}}
    else
      {:noreply, new_state}
    end
  end
  
  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end
  
  @impl true
  def handle_info(:process_queue, state) do
    case :queue.out(state.episode_queue) do
      {{:value, {episode, from}}, rest_queue} ->
        # Process the episode
        result = do_analyze(episode, state)
        
        # Reply to caller
        GenServer.reply(from, result)
        
        # Update stats
        new_stats = case result do
          {:ok, _explanation} ->
            %{state.stats | 
              episodes_processed: state.stats.episodes_processed + 1,
              explanations_generated: state.stats.explanations_generated + 1
            }
          {:error, _} ->
            %{state.stats | errors: state.stats.errors + 1}
        end
        
        # Continue processing
        send(self(), :process_queue)
        {:noreply, %{state | episode_queue: rest_queue, stats: new_stats}}
        
      {:empty, _} ->
        # Queue is empty, stop processing
        {:noreply, %{state | processing: false}}
    end
  end
  
  # Private functions
  
  defp handle_episode_event(_event, measurements, metadata, _config) do
    # Convert telemetry event to Episode struct
    episode = %Episode{
      id: generate_episode_id(),
      facts: measurements[:facts] || [],
      severity: metadata[:severity] || "info",
      duration_ms: measurements[:duration_ms] || 0,
      started_at: metadata[:started_at],
      ended_at: metadata[:ended_at],
      labels: metadata[:labels] || %{},
      context: metadata[:context] || %{}
    }
    
    # Queue for analysis
    Task.start(fn ->
      analyze_episode(episode)
    end)
  end
  
  defp do_analyze(episode, state) do
    start_time = System.monotonic_time(:millisecond)
    
    try do
      # Generate prompt from episode
      prompt = build_analysis_prompt(episode)
      
      # Call LLM provider
      response = case state.provider do
        :mock ->
          mock_llm_response(episode)
          
        :openai ->
          call_openai(prompt, state)
          
        :anthropic ->
          call_anthropic(prompt, state)
          
        :local ->
          call_local_model(prompt, state)
          
        _ ->
          {:error, :unsupported_provider}
      end
      
      # Parse response into Explanation
      case response do
        {:ok, llm_output} ->
          explanation = parse_llm_response(llm_output, episode)
          
          # Emit telemetry
          duration = System.monotonic_time(:millisecond) - start_time
          :telemetry.execute(
            [:cyb, :s4, :llm, :analysis],
            %{duration_ms: duration, facts_count: length(episode.facts)},
            %{episode_id: episode.id, severity: episode.severity}
          )
          
          # Feed explanation back to S3 for action
          send_to_s3(explanation)
          
          {:ok, explanation}
          
        error ->
          Logger.error("LLM analysis failed: #{inspect(error)}")
          error
      end
    rescue
      error ->
        Logger.error("Episode analysis error: #{inspect(error)}")
        {:error, Exception.format(:error, error)}
    end
  end
  
  defp build_analysis_prompt(episode) do
    """
    Analyze this system episode and provide explanation with remediation actions.
    
    Episode ID: #{episode.id}
    Severity: #{episode.severity}
    Duration: #{episode.duration_ms}ms
    Facts: #{length(episode.facts)}
    
    Fact Summary:
    #{format_facts(episode.facts)}
    
    Context:
    #{Jason.encode!(episode.context, pretty: true)}
    
    Please provide:
    1. Executive summary (2-3 sentences)
    2. Root cause analysis
    3. Impact assessment
    4. Recommended actions (prioritized)
    5. Relevant SOP references
    
    Format response as JSON with fields:
    - summary: string
    - root_cause: string
    - impact: {severity: string, scope: string, affected_systems: [string]}
    - actions: [{type: string, description: string, priority: number, automated: boolean}]
    - sop_refs: [string]
    - confidence: float (0-1)
    """
  end
  
  defp format_facts(facts) when is_list(facts) do
    facts
    |> Enum.take(20)  # Limit to prevent token explosion
    |> Enum.map(fn fact ->
      "- #{Map.get(fact, "source", "unknown")}: #{Map.get(fact, "severity", "info")} (count: #{Map.get(fact, "count", 1)})"
    end)
    |> Enum.join("\n")
  end
  defp format_facts(_), do: "No facts available"
  
  defp mock_llm_response(episode) do
    # Mock response for testing
    {:ok, %{
      "summary" => "Detected #{episode.severity} episode with #{length(episode.facts)} facts over #{episode.duration_ms}ms",
      "root_cause" => "Mock analysis: Pattern indicates resource contention in S2 coordinator",
      "impact" => %{
        "severity" => episode.severity,
        "scope" => "localized",
        "affected_systems" => ["S2", "S3"]
      },
      "actions" => [
        %{
          "type" => "automated",
          "description" => "Increase S2 coordinator slot allocation",
          "priority" => 1,
          "automated" => true,
          "wasm_module" => "scale_coordinator"
        },
        %{
          "type" => "manual",
          "description" => "Review rate limiter thresholds",
          "priority" => 2,
          "automated" => false
        }
      ],
      "sop_refs" => ["SOP-001-SCALE", "SOP-002-REVIEW"],
      "confidence" => 0.85
    }}
  end
  
  defp call_openai(_prompt, _state) do
    # Implement OpenAI API call
    {:error, :not_implemented}
  end
  
  defp call_anthropic(_prompt, _state) do
    # Implement Anthropic API call
    {:error, :not_implemented}
  end
  
  defp call_local_model(_prompt, _state) do
    # Implement local model call (Ollama, etc.)
    {:error, :not_implemented}
  end
  
  defp parse_llm_response(response, episode) do
    %Explanation{
      episode_id: episode.id,
      summary: Map.get(response, "summary", ""),
      root_cause: Map.get(response, "root_cause", "Unknown"),
      impact_assessment: Map.get(response, "impact", %{}),
      recommended_actions: parse_actions(Map.get(response, "actions", [])),
      confidence: Map.get(response, "confidence", 0.5),
      reasoning: Map.get(response, "reasoning", ""),
      sop_references: Map.get(response, "sop_refs", [])
    }
  end
  
  defp parse_actions(actions) when is_list(actions) do
    Enum.map(actions, fn action ->
      %SOPAction{
        id: generate_action_id(),
        type: String.to_atom(Map.get(action, "type", "manual")),
        description: Map.get(action, "description", ""),
        wasm_module: Map.get(action, "wasm_module"),
        parameters: Map.get(action, "parameters", %{}),
        expected_outcome: Map.get(action, "expected_outcome", ""),
        rollback_plan: Map.get(action, "rollback_plan", ""),
        confidence: Map.get(action, "confidence", 0.5)
      }
    end)
  end
  defp parse_actions(_), do: []
  
  defp send_to_s3(explanation) do
    # Send explanation to S3 Control for execution
    message = %{
      type: "s4.explanation",
      explanation: explanation,
      timestamp: System.system_time(:millisecond)
    }
    
    # Could use AMQP or direct GenServer call
    case Process.whereis(Cybernetic.VSM.System3.Control) do
      nil -> 
        Logger.warning("S3 Control not available to receive explanation")
      pid ->
        send(pid, {:s4_explanation, message})
    end
    
    # Emit algedonic signal based on severity
    if explanation.confidence > 0.7 do
      emit_algedonic_signal(explanation)
    end
  end
  
  defp emit_algedonic_signal(explanation) do
    severity = case length(explanation.recommended_actions) do
      n when n > 5 -> :pain
      n when n > 2 -> :discomfort
      _ -> :mild
    end
    
    :telemetry.execute(
      [:cybernetic, :algedonic],
      %{severity: severity},
      %{
        source: "s4_llm_bridge",
        episode_id: explanation.episode_id,
        confidence: explanation.confidence
      }
    )
  end
  
  defp generate_episode_id do
    "episode_#{:erlang.unique_integer([:positive])}"
  end
  
  defp generate_action_id do
    "action_#{:erlang.unique_integer([:positive])}"
  end
end