defmodule Cybernetic.VSM.System5.PolicyIntelligence do
  @moduledoc """
  S5 Policy Intelligence Engine with Claude integration.

  Provides intelligent policy evolution, governance recommendations,
  and strategic guidance for the VSM framework using Claude reasoning.
  """

  use GenServer
  require Logger
  require OpenTelemetry.Tracer
  alias Cybernetic.VSM.System4.Providers.Anthropic
  alias Cybernetic.VSM.System4.Episode
  alias Cybernetic.VSM.System5.Policy

  @telemetry [:cybernetic, :s5, :policy_intelligence]

  @vsm_systems [:s1, :s2, :s3, :s4, :s5]

  defstruct [
    :anthropic_provider,
    :policy_history,
    :governance_rules,
    :meta_policies
  ]

  @type t :: %__MODULE__{
          anthropic_provider: Anthropic.t() | nil,
          policy_history: map(),
          governance_rules: list(),
          meta_policies: map()
        }

  # Public API
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Analyze policy evolution patterns and suggest improvements.
  """
  def analyze_policy_evolution(policy_id, context \\ %{}) do
    GenServer.call(__MODULE__, {:analyze_evolution, policy_id, context})
  end

  @doc """
  Generate governance recommendations for policy changes.
  """
  def recommend_governance(proposed_policy, current_policies \\ []) do
    GenServer.call(__MODULE__, {:recommend_governance, proposed_policy, current_policies})
  end

  @doc """
  Create meta-policies for organizational learning and adaptation.
  """
  def evolve_meta_policies(system_metrics, historical_data) do
    GenServer.call(__MODULE__, {:evolve_meta_policies, system_metrics, historical_data})
  end

  @doc """
  Evaluate policy alignment across VSM systems.
  """
  def assess_system_alignment(policies_by_system) do
    GenServer.call(__MODULE__, {:assess_alignment, policies_by_system})
  end

  @impl true
  def init(opts) do
    # Initialize Anthropic provider
    anthropic_opts = Keyword.get(opts, :anthropic, [])

    state = %__MODULE__{
      anthropic_provider: nil,
      policy_history: %{},
      governance_rules: default_governance_rules(),
      meta_policies: default_meta_policies()
    }

    case Anthropic.new(anthropic_opts) do
      {:ok, provider} ->
        state = %{state | anthropic_provider: provider}
        Logger.info("S5 Policy Intelligence initialized with Claude integration")
        {:ok, state}

      {:error, reason} ->
        Logger.warning("Failed to initialize Anthropic provider: #{inspect(reason)}")
        Logger.info("S5 Policy Intelligence running without Claude integration")
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:analyze_evolution, policy_id, context}, _from, state) do
    result = do_analyze_evolution(state, policy_id, context)
    {:reply, result, state}
  end

  def handle_call({:recommend_governance, proposed_policy, current_policies}, _from, state) do
    result =
      OpenTelemetry.Tracer.with_span "s5.policy_intelligence.recommend_governance", %{
        attributes: %{proposed_policy_type: proposed_policy["type"]}
      } do
        do_recommend_governance(state, proposed_policy, current_policies)
      end

    {:reply, result, state}
  end

  def handle_call({:evolve_meta_policies, system_metrics, historical_data}, _from, state) do
    result =
      OpenTelemetry.Tracer.with_span "s5.policy_intelligence.evolve_meta_policies", %{
        attributes: %{metrics_count: map_size(system_metrics)}
      } do
        do_evolve_meta_policies(state, system_metrics, historical_data)
      end

    {:reply, result, update_meta_policies(state, result)}
  end

  def handle_call({:assess_alignment, policies_by_system}, _from, state) do
    result =
      OpenTelemetry.Tracer.with_span "s5.policy_intelligence.assess_alignment", %{
        attributes: %{systems_count: map_size(policies_by_system)}
      } do
        do_assess_alignment(state, policies_by_system)
      end

    {:reply, result, state}
  end

  # Private implementation functions

  defp do_analyze_evolution(state, policy_id, context) do
    result =
      with {:ok, policy_history} <- get_policy_history(policy_id),
           {:ok, analysis} <-
             analyze_with_claude(state, :policy_evolution, %{
               policy_id: policy_id,
               history: policy_history,
               context: context
             }) do
        {:ok, analysis}
      else
        {:error, :no_claude} ->
          {:ok, fallback_evolution_analysis(policy_id, context)}

        {:error, :policy_not_found} ->
          {:ok, fallback_evolution_analysis(policy_id, context)}

        error ->
          Logger.error("Policy evolution analysis failed: #{inspect(error)}")
          error
      end

    case result do
      {:ok, _analysis} ->
        :telemetry.execute(@telemetry ++ [:analysis], %{count: 1}, %{
          type: :evolution,
          policy_id: policy_id
        })

      _error ->
        :ok
    end

    result
  end

  defp do_recommend_governance(state, proposed_policy, current_policies) do
    governance_context = %{
      proposed: proposed_policy,
      current: current_policies,
      rules: state.governance_rules,
      meta_policies: state.meta_policies
    }

    case analyze_with_claude(state, :governance_recommendation, governance_context) do
      {:ok, recommendations} ->
        :telemetry.execute(@telemetry ++ [:governance], %{count: 1}, %{
          proposed_type: proposed_policy["type"]
        })

        {:ok, recommendations}

      {:error, :no_claude} ->
        {:ok,
         fallback_governance_check(proposed_policy, current_policies, state.governance_rules)}

      error ->
        Logger.error("Governance recommendation failed: #{inspect(error)}")
        error
    end
  end

  defp do_evolve_meta_policies(state, system_metrics, historical_data) do
    evolution_context = %{
      current_meta_policies: state.meta_policies,
      system_metrics: system_metrics,
      historical_data: historical_data,
      performance_trends: extract_trends(historical_data)
    }

    case analyze_with_claude(state, :meta_policy_evolution, evolution_context) do
      {:ok, evolved_policies} ->
        :telemetry.execute(@telemetry ++ [:meta_evolution], %{count: 1}, %{
          policies_evolved: map_size(evolved_policies)
        })

        {:ok, evolved_policies}

      {:error, :no_claude} ->
        {:ok, adaptive_meta_policy_evolution(state.meta_policies, system_metrics)}

      error ->
        Logger.error("Meta-policy evolution failed: #{inspect(error)}")
        error
    end
  end

  defp do_assess_alignment(state, policies_by_system) do
    alignment_context = %{
      s1_policies: Map.get(policies_by_system, :s1, []),
      s2_policies: Map.get(policies_by_system, :s2, []),
      s3_policies: Map.get(policies_by_system, :s3, []),
      s4_policies: Map.get(policies_by_system, :s4, []),
      s5_policies: Map.get(policies_by_system, :s5, []),
      meta_policies: state.meta_policies
    }

    case analyze_with_claude(state, :system_alignment, alignment_context) do
      {:ok, alignment_report} ->
        :telemetry.execute(@telemetry ++ [:alignment], %{count: 1}, %{
          systems_analyzed: map_size(policies_by_system)
        })

        {:ok, alignment_report}

      {:error, :no_claude} ->
        {:ok, basic_alignment_check(policies_by_system)}

      error ->
        Logger.error("System alignment assessment failed: #{inspect(error)}")
        error
    end
  end

  defp analyze_with_claude(state, analysis_type, context) do
    if state.anthropic_provider do
      episode = build_policy_episode(analysis_type, context)

      # All inference goes through the S4 Router — the single choke
      # point where the S3 budget check is enforced. Calling the
      # Anthropic provider directly (as this module used to) bypassed
      # the budget entirely. The episode kinds built below lead their
      # Router chains with Anthropic, preserving the Claude-first
      # behavior while gaining fallback and budget enforcement.
      case Cybernetic.VSM.System4.Router.route(episode) do
        {:ok, result, _provider_info} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_claude}
    end
  end

  defp build_policy_episode(analysis_type, context) do
    kind =
      case analysis_type do
        :policy_evolution -> :policy_review
        :governance_recommendation -> :compliance_check
        :meta_policy_evolution -> :optimization
        :system_alignment -> :policy_review
      end

    title =
      case analysis_type do
        :policy_evolution -> "Policy Evolution Analysis"
        :governance_recommendation -> "Governance Recommendation"
        :meta_policy_evolution -> "Meta-Policy Evolution"
        :system_alignment -> "System Alignment Assessment"
      end

    Episode.new(
      kind,
      title,
      context,
      priority: :normal,
      metadata: %{
        analysis_type: analysis_type,
        source_system: :s5
      }
    )
  end

  # Fallback implementations when Claude is not available.
  #
  # Phase 1 (IP-32): the non-LLM layer computes real answers from
  # the policy corpus and metrics it is handed. There are no
  # constants wearing a lab coat: where the inputs carry no signal,
  # the result says so (:insufficient_data, evolution_score: nil)
  # instead of inventing a number. The detectors verify the internal
  # consistency of the corpus they receive; they cannot prove the
  # corpus complete.

  defp fallback_evolution_analysis(policy_id, _context) do
    %{
      summary: "Basic policy evolution analysis without Claude integration",
      recommendations: [
        %{
          "type" => "monitoring",
          "action" => "Track policy usage metrics for #{policy_id}",
          "rationale" => "Data-driven policy improvement",
          "system" => "s5"
        }
      ],
      risk_level: "low",
      # No score: an evolution score needs a policy history this
      # fallback does not have (D7 - removed, not proxied).
      evolution_score: nil,
      evolution_score_reason: :unavailable_without_history
    }
  end

  defp fallback_governance_check(proposed_policy, current_policies, rules) do
    conflicts = check_rule_violations(proposed_policy, current_policies, rules)
    overlaps = find_policy_overlaps(proposed_policy, current_policies)

    %{
      summary: "Rule-based governance check completed",
      conflicts: conflicts,
      overlaps: overlaps,
      approval_status: if(Enum.empty?(conflicts), do: "approved", else: "requires_review"),
      recommendations: generate_governance_recommendations(conflicts, overlaps)
    }
  end

  defp adaptive_meta_policy_evolution(current_meta_policies, system_metrics) do
    case calculate_system_performance(system_metrics) do
      :insufficient_data ->
        %{
          evolved_policies: current_meta_policies,
          adaptation_reason: :insufficient_data,
          performance_score: :insufficient_data,
          confidence: 0.0
        }

      {performance_score, confidence} ->
        adapted_policies =
          current_meta_policies
          |> adjust_for_performance(performance_score)
          |> Map.put(:last_evolution, System.system_time(:millisecond))

        %{
          evolved_policies: adapted_policies,
          adaptation_reason: "Performance-based adjustment",
          performance_score: performance_score,
          # Confidence is the fraction of the formula's inputs that
          # were actually present (1.0 / 0.67 / 0.33) - evidence
          # about the evidence.
          confidence: confidence
        }
    end
  end

  defp basic_alignment_check(policies_by_system) do
    policies_by_system = normalize_systems_map(policies_by_system)
    all_policies = ordered_policies(policies_by_system)

    conflicts = detect_policy_conflicts(all_policies)
    coverage_gaps = detect_coverage_gaps(policies_by_system)

    %{
      alignment_score: calculate_alignment_score(conflicts, coverage_gaps, policies_by_system),
      conflicts: conflicts,
      coverage_gaps: coverage_gaps,
      recommendations: alignment_recommendations(conflicts, coverage_gaps)
    }
  end

  # Helper functions

  defp get_policy_history(policy_id) do
    try do
      case Policy.get_policy(policy_id) do
        nil -> {:error, :policy_not_found}
        # In real implementation, get full history
        policy -> {:ok, [policy]}
      end
    catch
      :exit, _ -> {:error, :policy_not_found}
    end
  end

  defp default_governance_rules do
    [
      %{
        rule: "no_conflicting_authority",
        description: "Policies cannot overlap authority domains"
      },
      %{rule: "versioning_required", description: "All policy changes must be versioned"},
      %{rule: "impact_assessment", description: "High-impact policies require assessment"},
      %{rule: "stakeholder_approval", description: "Cross-system policies need approval"}
    ]
  end

  defp default_meta_policies do
    %{
      learning_rate: 0.1,
      adaptation_threshold: 0.8,
      governance_strictness: :medium,
      evolution_frequency: :weekly,
      performance_weight: 0.7,
      stability_weight: 0.3
    }
  end

  defp extract_trends(historical_data) do
    # Simple trend extraction - in real implementation, use proper time series analysis
    Map.get(historical_data, :trends, %{})
  end

  defp update_meta_policies(state, {:ok, %{evolved_policies: new_policies}}) do
    %{state | meta_policies: new_policies}
  end

  defp update_meta_policies(state, _), do: state

  # ========== IP-32: real detectors and scorers ==========
  #
  # Policy shapes vary across the codebase (atom or string keys,
  # rules as a map or a list), so every reader below is defensive:
  # a policy with no readable rules simply contributes nothing to
  # rule-based findings, but still counts for scope/version checks.

  # --- policy field readers ---

  defp policy_field(policy, key) when is_map(policy) do
    Map.get(policy, key) || Map.get(policy, Atom.to_string(key))
  end

  defp policy_field(_policy, _key), do: nil

  defp policy_rules(policy) do
    case policy_field(policy, :rules) do
      rules when is_map(rules) ->
        Map.new(rules, fn {key, value} -> {to_string(key), value} end)

      rules when is_list(rules) ->
        Map.new(rules, fn
          rule when is_map(rule) ->
            name = policy_field(rule, :rule) || policy_field(rule, :name)
            {to_string(name), rule}

          rule ->
            {to_string(rule), true}
        end)

      _other ->
        %{}
    end
  end

  # The authority domain a policy claims: an explicit domain field
  # when present, otherwise its type (the corpus's working notion
  # of what the policy governs).
  defp authority_domain(policy) do
    case policy_field(policy, :authority_domain) || policy_field(policy, :domain) ||
           policy_field(policy, :type) do
      nil -> nil
      domain -> to_string(domain)
    end
  end

  defp policy_label(policy) do
    policy_field(policy, :id) || policy_field(policy, :name) || inspect(policy)
  end

  defp cross_system_scope?(policy) do
    systems = policy_field(policy, :systems)

    policy_field(policy, :scope) in ["cross_system", :cross_system] or
      (is_list(systems) and length(systems) > 1)
  end

  # --- governance detectors ---

  defp check_rule_violations(proposed_policy, current_policies, rules) do
    rule_names = MapSet.new(Enum.map(rules, &rule_name/1))

    []
    |> add_violation(
      MapSet.member?(rule_names, "no_conflicting_authority"),
      authority_overlap_violations(proposed_policy, current_policies)
    )
    |> add_violation(
      MapSet.member?(rule_names, "versioning_required") and
        is_nil(policy_field(proposed_policy, :version)),
      [
        %{
          rule: "versioning_required",
          policy: policy_label(proposed_policy),
          detail: "proposed policy carries no version field"
        }
      ]
    )
    |> add_violation(
      MapSet.member?(rule_names, "stakeholder_approval") and
        cross_system_scope?(proposed_policy) and
        policy_field(proposed_policy, :stakeholder_approval) not in [true, "approved", :approved],
      [
        %{
          rule: "stakeholder_approval",
          policy: policy_label(proposed_policy),
          detail: "cross-system scope without a stakeholder approval marker"
        }
      ]
    )
    |> add_violation(
      MapSet.member?(rule_names, "impact_assessment") and
        policy_field(proposed_policy, :impact) in ["high", :high] and
        is_nil(policy_field(proposed_policy, :impact_assessment)),
      [
        %{
          rule: "impact_assessment",
          policy: policy_label(proposed_policy),
          detail: "high-impact policy without an impact assessment"
        }
      ]
    )
    |> List.flatten()
  end

  defp add_violation(violations, true, new), do: violations ++ new
  defp add_violation(violations, _false, _new), do: violations

  defp rule_name(rule) when is_map(rule), do: to_string(policy_field(rule, :rule))
  defp rule_name(rule), do: to_string(rule)

  # A proposed policy violates no_conflicting_authority when an
  # existing policy claims the same authority domain and the two
  # set a shared rule key to different values.
  defp authority_overlap_violations(proposed_policy, current_policies) do
    proposed_domain = authority_domain(proposed_policy)
    proposed_rules = policy_rules(proposed_policy)

    if is_nil(proposed_domain) do
      []
    else
      Enum.flat_map(current_policies, fn existing ->
        conflicting_keys =
          if authority_domain(existing) == proposed_domain do
            existing_rules = policy_rules(existing)

            Enum.filter(Map.keys(proposed_rules), fn key ->
              Map.has_key?(existing_rules, key) and existing_rules[key] != proposed_rules[key]
            end)
          else
            []
          end

        if conflicting_keys == [] do
          []
        else
          [
            %{
              rule: "no_conflicting_authority",
              policy: policy_label(proposed_policy),
              detail:
                "authority domain #{proposed_domain} already claimed by " <>
                  "#{policy_label(existing)} with conflicting keys: " <>
                  Enum.join(conflicting_keys, ", ")
            }
          ]
        end
      end)
    end
  end

  defp find_policy_overlaps(proposed_policy, current_policies) do
    proposed_domain = authority_domain(proposed_policy)
    proposed_rules = policy_rules(proposed_policy)

    Enum.flat_map(current_policies, fn existing ->
      existing_domain = authority_domain(existing)
      existing_rules = policy_rules(existing)

      shared_domain? = not is_nil(proposed_domain) and proposed_domain == existing_domain

      conflicting_keys =
        proposed_rules
        |> Map.keys()
        |> Enum.filter(fn key ->
          Map.has_key?(existing_rules, key) and existing_rules[key] != proposed_rules[key]
        end)

      shared_key? = conflicting_keys != [] or maps_share_key?(proposed_rules, existing_rules)

      if shared_domain? or shared_key? do
        [
          %{
            policy: policy_label(existing),
            shared_domain: if(shared_domain?, do: proposed_domain),
            conflicting_keys: conflicting_keys
          }
        ]
      else
        []
      end
    end)
  end

  defp maps_share_key?(map_a, map_b) do
    Enum.any?(Map.keys(map_a), &Map.has_key?(map_b, &1))
  end

  defp generate_governance_recommendations(conflicts, overlaps) do
    conflict_recs =
      Enum.map(conflicts, fn conflict ->
        %{
          "type" => "governance_violation",
          "action" =>
            "Resolve #{conflict.rule} for policy #{conflict.policy}: #{conflict.detail}",
          "rationale" => "Governance rule #{conflict.rule} is violated",
          "system" => "s5"
        }
      end)

    overlap_recs =
      Enum.map(overlaps, fn overlap ->
        %{
          "type" => "policy_overlap",
          "action" =>
            "Reconcile overlapping policy #{overlap.policy}" <>
              if(overlap.conflicting_keys != [],
                do: " (conflicting keys: #{Enum.join(overlap.conflicting_keys, ", ")})",
                else: ""
              ),
          "rationale" => "Overlapping authority produces conflicting directives",
          "system" => "s5"
        }
      end)

    conflict_recs ++ overlap_recs
  end

  # --- meta-policy performance ---

  # performance = 0.4*success_rate + 0.3*(1 - denial_rate)
  #             + 0.3*(1 - min(error_rate*5, 1))
  #
  # Inputs are read under atom or string keys and clamped to [0, 1].
  # With no inputs at all the honest answer is :insufficient_data.
  # With some inputs, the formula runs over the present ones with
  # weights renormalized, and the second tuple element reports the
  # fraction of inputs present (the confidence).
  defp calculate_system_performance(metrics) when is_map(metrics) do
    inputs = [
      {:success_rate, 0.4, fn rate -> rate end},
      {:denial_rate, 0.3, fn rate -> 1 - rate end},
      {:error_rate, 0.3, fn rate -> 1 - min(rate * 5, 1) end}
    ]

    present =
      Enum.flat_map(inputs, fn {key, weight, transform} ->
        case metric_value(metrics, key) do
          nil -> []
          value -> [{weight, transform.(clamp01(value))}]
        end
      end)

    case present do
      [] ->
        :insufficient_data

      _ ->
        total_weight = present |> Enum.map(&elem(&1, 0)) |> Enum.sum()

        score =
          Enum.reduce(present, 0.0, fn {weight, value}, acc ->
            acc + weight / total_weight * value
          end)

        {score, length(present) / 3}
    end
  end

  defp calculate_system_performance(_metrics), do: :insufficient_data

  defp metric_value(metrics, key) do
    case Map.get(metrics, key) || Map.get(metrics, Atom.to_string(key)) do
      value when is_number(value) -> value / 1
      _other -> nil
    end
  end

  defp clamp01(value), do: value |> max(0.0) |> min(1.0)

  # The adaptation rule: below 0.5 the system tightens governance
  # and slows learning; 0.5-0.8 holds; above 0.8 learning speeds up
  # (capped). A posture with no number behind it does not move.
  defp adjust_for_performance(policies, score) when score < 0.5 do
    policies
    |> Map.update(:governance_strictness, :high, &step_up_strictness/1)
    |> Map.update(:learning_rate, 0.05, &(&1 * 0.5))
  end

  defp adjust_for_performance(policies, score) when score > 0.8 do
    Map.update(policies, :learning_rate, 0.11, &min(&1 * 1.1, 1.0))
  end

  defp adjust_for_performance(policies, _score), do: policies

  defp step_up_strictness(:low), do: :medium
  defp step_up_strictness(:medium), do: :high
  defp step_up_strictness(:high), do: :high
  defp step_up_strictness(_other), do: :high

  # --- alignment detectors ---

  # Policies flattened in canonical VSM system order (s1..s5, then
  # any extra systems by name). Map iteration order is not stable
  # across VM boots, and detector findings must not depend on it.
  defp ordered_policies(policies_by_system) do
    ordered =
      Enum.flat_map(@vsm_systems, fn system ->
        Map.get(policies_by_system, system, [])
      end)

    extras =
      policies_by_system
      |> Map.drop(@vsm_systems)
      |> Enum.sort_by(fn {system, _policies} -> to_string(system) end)
      |> Enum.flat_map(fn {_system, policies} -> policies end)

    ordered ++ extras
  end

  defp detect_policy_conflicts(all_policies) do
    all_policies
    |> Enum.map(fn policy -> {policy_label(policy), policy_rules(policy)} end)
    |> pairwise()
    |> Enum.flat_map(fn {{label_a, rules_a}, {label_b, rules_b}} ->
      rules_a
      |> Map.keys()
      |> Enum.filter(fn key ->
        Map.has_key?(rules_b, key) and rules_b[key] != rules_a[key]
      end)
      |> Enum.map(fn key ->
        %{
          rule_key: key,
          policies: [label_a, label_b],
          values: [rules_a[key], rules_b[key]]
        }
      end)
    end)
  end

  # Callers key policies_by_system inconsistently (atoms in most
  # code, strings in some payloads); the gap detector compares
  # against the VSM system atoms, so normalize s1..s5 keys first.
  defp normalize_systems_map(policies_by_system) do
    Map.new(policies_by_system, fn {system, policies} ->
      normalized =
        case to_string(system) do
          "s1" -> :s1
          "s2" -> :s2
          "s3" -> :s3
          "s4" -> :s4
          "s5" -> :s5
          _other -> system
        end

      {normalized, policies}
    end)
  end

  defp detect_coverage_gaps(policies_by_system) do
    missing_systems =
      for system <- @vsm_systems,
          Map.get(policies_by_system, system, []) == [],
          do: %{type: :system_without_policy, system: system}

    rule_gaps =
      policies_by_system
      |> Enum.flat_map(fn {system, policies} ->
        domain_keys =
          policies_by_system
          |> Enum.reject(fn {other, _} -> other == system end)
          |> Enum.flat_map(fn {_other, other_policies} -> other_policies end)
          |> Enum.filter(fn other ->
            not is_nil(authority_domain(other)) and
              Enum.any?(policies, fn own ->
                authority_domain(own) == authority_domain(other)
              end)
          end)
          |> Enum.flat_map(fn other -> Map.keys(policy_rules(other)) end)
          |> MapSet.new()

        own_keys =
          policies
          |> Enum.flat_map(fn policy -> Map.keys(policy_rules(policy)) end)
          |> MapSet.new()

        domain_keys
        |> MapSet.difference(own_keys)
        |> Enum.map(fn key -> %{type: :missing_rule_key, system: system, rule_key: key} end)
      end)

    missing_systems ++ rule_gaps
  end

  # alignment_score = 1 - (weighted findings / weighted possible)
  # where conflicts weigh 1.0 and gaps 0.5, and the denominator is
  # the total rule keys examined plus the systems examined. 1.0 is
  # reachable only when the detectors actually ran and found
  # nothing; an empty corpus scores 0.0 (nothing was examined).
  defp calculate_alignment_score(conflicts, gaps, policies_by_system) do
    rule_keys_examined =
      policies_by_system
      |> Enum.flat_map(fn {_system, policies} -> policies end)
      |> Enum.flat_map(fn policy -> Map.keys(policy_rules(policy)) end)
      |> Enum.uniq()
      |> length()

    possible = rule_keys_examined + length(@vsm_systems)

    if possible == 0 or rule_keys_examined == 0 do
      0.0
    else
      weighted = length(conflicts) * 1.0 + length(gaps) * 0.5
      (1 - weighted / possible) |> clamp01()
    end
  end

  defp alignment_recommendations(conflicts, gaps) do
    conflict_recs =
      Enum.map(conflicts, fn conflict ->
        %{
          "type" => "alignment_conflict",
          "action" =>
            "Align rule #{conflict.rule_key} between #{Enum.join(conflict.policies, " and ")}",
          "rationale" => "The same rule key is set differently by two policies",
          "system" => "s5"
        }
      end)

    gap_recs =
      Enum.map(gaps, fn gap ->
        %{
          "type" => "coverage_gap",
          "action" => "Close coverage gap: #{inspect(gap)}",
          "rationale" => "Uncovered systems and rule keys cannot be governed",
          "system" => "s5"
        }
      end)

    conflict_recs ++ gap_recs
  end

  defp pairwise(list) do
    for {a, i} <- Enum.with_index(list), {b, j} <- Enum.with_index(list), i < j, do: {a, b}
  end
end
