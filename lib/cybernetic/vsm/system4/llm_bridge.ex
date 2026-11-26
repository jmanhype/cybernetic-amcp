defmodule Cybernetic.VSM.System4.LLMBridge do
  @moduledoc """
  Bridges aggregated 'episodes' to LLM analysis and emits actionable outputs.

  Input: episodes from Central Aggregator (via PubSub or direct GenServer call).
  Output: telemetry + message to SOP engine with suggestions.

  Episodes are analyzed through `Cybernetic.VSM.System4.Router` —
  the single choke point for provider calls, where the S3 budget
  check is enforced. This bridge used to call a configured provider
  directly, which bypassed the budget entirely (Axiomatic Design
  coupling register #1). Deployments that want the old no-op
  behavior can put `:null` in the Router chain for the episode kind.
  """
  use GenServer
  require Logger

  alias Cybernetic.VSM.System4.Episode
  alias Cybernetic.VSM.System4.Router

  @telemetry [:cybernetic, :s4, :llm]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    sub = Keyword.get(opts, :subscribe, &__MODULE__.default_subscribe/1)
    sub.(self())
    {:ok, %{router_opts: Keyword.get(opts, :router_opts, [])}}
  end

  # Hook for your Aggregator to send episodes to S4
  @impl true
  def handle_cast({:episode, ep}, state) do
    :telemetry.execute(@telemetry ++ [:request], %{count: 1}, %{episode: meta(ep)})

    episode = to_episode(ep)

    case Router.route(episode, state.router_opts) do
      {:ok, result, _provider_info} ->
        :telemetry.execute(@telemetry ++ [:response], %{count: 1}, %{
          size: byte_size(result.summary || "")
        })

        notify_sop_engine(result, ep)
        {:noreply, state}

      {:error, reason} ->
        :telemetry.execute(@telemetry ++ [:error], %{count: 1}, %{reason: inspect(reason)})
        {:noreply, state}
    end
  end

  # The telemetry subscription delivers episodes as plain messages,
  # not casts — handle them on the same path. (Before this, those
  # messages fell into the default handle_info and were dropped.)
  @impl true
  def handle_info({:episode, ep}, state) do
    handle_cast({:episode, ep}, state)
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Aggregator episodes arrive as plain maps with string keys (see
  # meta/1). Convert to the %Episode{} the Router routes on.
  defp to_episode(ep) when is_map(ep) do
    kind = episode_kind(ep["type"] || ep[:type])
    severity = ep["severity"] || ep[:severity]

    %Episode{
      id: ep["id"] || ep[:id] || Episode.generate_id(),
      kind: kind,
      title: "Aggregator episode: #{ep["type"] || ep[:type] || "unknown"}",
      data: ep,
      metadata: %{
        window_start: ep["window_start"] || ep[:window_start],
        window_end: ep["window_end"] || ep[:window_end],
        severity: severity
      },
      priority: episode_priority(severity),
      created_at: DateTime.utc_now(),
      source_system: :aggregator
    }
  end

  defp episode_kind(type) when is_binary(type) do
    case type do
      "policy_review" -> :policy_review
      "root_cause" -> :root_cause
      "code_gen" -> :code_gen
      "anomaly_detection" -> :anomaly_detection
      "compliance_check" -> :compliance_check
      "optimization" -> :optimization
      "prediction" -> :prediction
      "classification" -> :classification
      _other -> :anomaly_detection
    end
  end

  defp episode_kind(kind) when is_atom(kind) and not is_nil(kind), do: kind
  defp episode_kind(_other), do: :anomaly_detection

  defp episode_priority("critical"), do: :critical
  defp episode_priority("high"), do: :high
  defp episode_priority("low"), do: :low
  defp episode_priority(severity) when is_atom(severity) and not is_nil(severity), do: severity
  defp episode_priority(_other), do: :normal

  defp notify_sop_engine(res, ep) do
    # Extract sop_suggestions from either atom or string keys
    sop_suggestions =
      Map.get(res, :sop_suggestions) ||
        Map.get(res, "sop_suggestions") ||
        []

    # Extract recommendations from either atom or string keys
    recommendations =
      Map.get(res, :recommendations) ||
        Map.get(res, "recommendations") ||
        []

    # Only send if we have suggestions
    if is_list(sop_suggestions) and length(sop_suggestions) > 0 do
      payload = %{
        episode: ep,
        sop_suggestions: sop_suggestions,
        recommendations: recommendations
      }

      send(Cybernetic.VSM.System5.SOPEngine, {:s4_suggestions, payload})
    end

    :ok
  end

  def handle_episode_event(_event, _measurements, metadata, pid) do
    send(pid, {:episode, metadata.episode})
  end

  def default_subscribe(pid) do
    # Replace with your real aggregator subscription; minimal safe default:
    :ok =
      :telemetry.attach_many(
        {:s4_bridge, make_ref()},
        [[:cybernetic, :aggregator, :episode]],
        &__MODULE__.handle_episode_event/4,
        pid
      )
  end

  defp meta(ep) do
    Map.take(ep, ["id", "type", "severity", "window_start", "window_end"])
  end
end
