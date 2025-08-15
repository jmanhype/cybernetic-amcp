#!/usr/bin/env elixir

# Live test script for S5 Policy Intelligence Engine with Claude integration
# Run with: elixir test_policy_intelligence_live.exs

Mix.install([
  {:jason, "~> 1.4"},
  {:httpoison, "~> 2.2"}
])

defmodule Cybernetic.VSM.System5.PolicyIntelligence do
  @moduledoc """
  S5 Policy Intelligence Engine - Live Test Version
  """
  
  require Logger
  
  defstruct [
    :anthropic_provider,
    :governance_rules,
    :meta_policies
  ]
  
  def new(opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")
    
    unless api_key do
      {:error, :missing_api_key}
    else
      provider = %{
        api_key: api_key,
        model: "claude-3-5-sonnet-20241022",
        base_url: "https://api.anthropic.com",
        timeout: 30_000
      }
      
      engine = %__MODULE__{
        anthropic_provider: provider,
        governance_rules: default_governance_rules(),
        meta_policies: default_meta_policies()
      }
      
      {:ok, engine}
    end
  end
  
  def analyze_policy_evolution(engine, policy_context) do
    prompt = build_policy_evolution_prompt(policy_context)
    make_claude_request(engine.anthropic_provider, prompt)
  end
  
  def recommend_governance(engine, governance_context) do
    prompt = build_governance_prompt(governance_context)
    make_claude_request(engine.anthropic_provider, prompt)
  end
  
  def evolve_meta_policies(engine, evolution_context) do
    prompt = build_meta_policy_prompt(evolution_context)
    make_claude_request(engine.anthropic_provider, prompt)
  end
  
  def assess_system_alignment(engine, alignment_context) do
    prompt = build_alignment_prompt(alignment_context)
    make_claude_request(engine.anthropic_provider, prompt)
  end
  
  defp build_policy_evolution_prompt(context) do
    system_prompt = """
    You are the S5 Policy Intelligence system in a Viable System Model (VSM) framework.
    Your role is to analyze policy evolution patterns and provide strategic governance recommendations.
    
    Analyze the given policy context and provide:
    1. Evolution pattern assessment
    2. Policy effectiveness analysis  
    3. Strategic improvement recommendations
    4. Risk assessment for policy changes
    
    Respond in JSON format with the following structure:
    {
      "summary": "Policy evolution analysis summary",
      "evolution_patterns": ["pattern1", "pattern2"],
      "effectiveness_score": 0.85,
      "improvement_recommendations": [
        {
          "type": "immediate|short_term|long_term",
          "action": "Specific recommendation",
          "rationale": "Why this is important",
          "impact": "high|medium|low"
        }
      ],
      "risk_assessment": {
        "current_risk_level": "low|medium|high|critical",
        "change_risks": ["risk1", "risk2"],
        "mitigation_strategies": ["strategy1", "strategy2"]
      },
      "governance_alignment": "excellent|good|fair|poor"
    }
    """
    
    user_prompt = """
    Policy Evolution Context:
    
    Policy ID: #{context[:policy_id]}
    Domain: #{context[:domain]}
    Current Version: #{context[:current_version] || "1.0"}
    Last Review: #{context[:last_review] || "Never"}
    
    Performance Metrics:
    #{Jason.encode!(context[:performance_metrics] || %{}, pretty: true)}
    
    Historical Changes:
    #{Jason.encode!(context[:change_history] || [], pretty: true)}
    
    Business Context:
    #{Jason.encode!(context[:business_context] || %{}, pretty: true)}
    
    Please analyze this policy evolution context and provide strategic recommendations.
    """
    
    %{
      "model" => "claude-3-5-sonnet-20241022",
      "max_tokens" => 4096,
      "temperature" => 0.1,
      "system" => system_prompt,
      "messages" => [
        %{
          "role" => "user",
          "content" => user_prompt
        }
      ]
    }
  end
  
  defp build_governance_prompt(context) do
    system_prompt = """
    You are the S5 Policy Governance system in a VSM framework.
    Your role is to evaluate proposed policies against governance frameworks and organizational coherence.
    
    Analyze the governance context and provide:
    1. Compliance assessment with existing governance rules
    2. Conflict detection with current policies
    3. Authority and responsibility mapping
    4. Implementation risk analysis
    
    Respond in JSON format:
    {
      "summary": "Governance analysis summary",
      "compliance_status": "compliant|partial|non_compliant",
      "conflicts_detected": [
        {
          "type": "authority_overlap|contradiction|gap",
          "description": "Conflict description",
          "severity": "high|medium|low",
          "affected_policies": ["policy1", "policy2"]
        }
      ],
      "approval_recommendation": "approve|conditional_approve|reject|requires_review",
      "conditions": ["condition1", "condition2"],
      "implementation_risks": [
        {
          "risk": "Risk description",
          "probability": "high|medium|low", 
          "impact": "high|medium|low",
          "mitigation": "Mitigation strategy"
        }
      ],
      "authority_mapping": {
        "decision_authority": "s1|s2|s3|s4|s5",
        "implementation_authority": "s1|s2|s3|s4|s5",
        "oversight_authority": "s1|s2|s3|s4|s5"
      }
    }
    """
    
    user_prompt = """
    Governance Analysis Context:
    
    Proposed Policy:
    #{Jason.encode!(context[:proposed_policy], pretty: true)}
    
    Current Policy Framework:
    #{Jason.encode!(context[:current_policies] || [], pretty: true)}
    
    Governance Rules:
    #{Jason.encode!(context[:governance_rules] || [], pretty: true)}
    
    Organizational Context:
    #{Jason.encode!(context[:org_context] || %{}, pretty: true)}
    
    Please evaluate this policy proposal against our governance framework.
    """
    
    %{
      "model" => "claude-3-5-sonnet-20241022",
      "max_tokens" => 4096,
      "temperature" => 0.1,
      "system" => system_prompt,
      "messages" => [
        %{
          "role" => "user",
          "content" => user_prompt
        }
      ]
    }
  end
  
  defp build_meta_policy_prompt(context) do
    system_prompt = """
    You are the S5 Meta-Policy Evolution system in a VSM framework.
    Your role is to evolve the policies that govern how policies are created, modified, and retired.
    
    Analyze the evolution context and provide:
    1. Meta-policy effectiveness assessment
    2. Organizational learning insights
    3. Adaptive governance recommendations
    4. System-wide coherence improvements
    
    Respond in JSON format:
    {
      "summary": "Meta-policy evolution analysis",
      "current_effectiveness": 0.78,
      "learning_insights": [
        {
          "insight": "Key learning",
          "evidence": "Supporting evidence",
          "implications": "What this means for meta-policies"
        }
      ],
      "evolved_meta_policies": {
        "policy_creation_rules": {...},
        "change_management_rules": {...},
        "governance_adaptation_rules": {...}
      },
      "organizational_maturity": {
        "current_level": "reactive|adaptive|predictive|generative",
        "progression_path": ["step1", "step2"],
        "capability_gaps": ["gap1", "gap2"]
      },
      "system_coherence_score": 0.82
    }
    """
    
    user_prompt = """
    Meta-Policy Evolution Context:
    
    Current Meta-Policies:
    #{Jason.encode!(context[:current_meta_policies], pretty: true)}
    
    System Performance Metrics:
    #{Jason.encode!(context[:system_metrics], pretty: true)}
    
    Historical Policy Data:
    #{Jason.encode!(context[:historical_data] || %{}, pretty: true)}
    
    Organizational Challenges:
    #{Jason.encode!(context[:challenges] || [], pretty: true)}
    
    Please analyze and evolve our meta-policy framework.
    """
    
    %{
      "model" => "claude-3-5-sonnet-20241022",
      "max_tokens" => 4096,
      "temperature" => 0.2,
      "system" => system_prompt,
      "messages" => [
        %{
          "role" => "user",
          "content" => user_prompt
        }
      ]
    }
  end
  
  defp build_alignment_prompt(context) do
    system_prompt = """
    You are the S5 System Alignment Analyzer in a VSM framework.
    Your role is to assess policy coherence across all 5 VSM systems and identify alignment opportunities.
    
    Analyze the alignment context and provide:
    1. Cross-system coherence assessment
    2. Policy conflict detection
    3. Coverage gap analysis
    4. Synergy opportunities identification
    
    Respond in JSON format:
    {
      "summary": "System alignment analysis",
      "overall_alignment_score": 0.86,
      "system_scores": {
        "s1_operational": 0.92,
        "s2_coordination": 0.84,
        "s3_control": 0.88,
        "s4_intelligence": 0.81,
        "s5_policy": 0.90
      },
      "conflicts": [
        {
          "systems": ["s1", "s3"],
          "conflict_type": "authority_overlap|contradiction|resource_contention",
          "description": "Conflict description",
          "resolution_strategy": "Strategy to resolve"
        }
      ],
      "coverage_gaps": [
        {
          "gap_area": "Security incident response",
          "affected_systems": ["s1", "s2"],
          "risk_level": "high|medium|low",
          "recommended_policy": "Policy recommendation"
        }
      ],
      "synergy_opportunities": [
        {
          "systems": ["s2", "s4"],
          "opportunity": "Opportunity description",
          "potential_benefit": "Expected benefit",
          "implementation_approach": "How to implement"
        }
      ]
    }
    """
    
    user_prompt = """
    System Alignment Context:
    
    S1 Operational Policies:
    #{Jason.encode!(context[:s1_policies] || [], pretty: true)}
    
    S2 Coordination Policies:
    #{Jason.encode!(context[:s2_policies] || [], pretty: true)}
    
    S3 Control Policies:
    #{Jason.encode!(context[:s3_policies] || [], pretty: true)}
    
    S4 Intelligence Policies:
    #{Jason.encode!(context[:s4_policies] || [], pretty: true)}
    
    S5 Policy Framework:
    #{Jason.encode!(context[:s5_policies] || [], pretty: true)}
    
    Organization Context:
    #{Jason.encode!(context[:org_context] || %{}, pretty: true)}
    
    Please assess policy alignment across all VSM systems.
    """
    
    %{
      "model" => "claude-3-5-sonnet-20241022",
      "max_tokens" => 4096,
      "temperature" => 0.1,
      "system" => system_prompt,
      "messages" => [
        %{
          "role" => "user",
          "content" => user_prompt
        }
      ]
    }
  end
  
  defp make_claude_request(provider, payload) do
    url = "#{provider.base_url}/v1/messages"
    headers = [
      {"Content-Type", "application/json"},
      {"x-api-key", provider.api_key},
      {"anthropic-version", "2023-06-01"}
    ]
    
    options = [
      timeout: provider.timeout,
      recv_timeout: provider.timeout
    ]
    
    with {:ok, json} <- Jason.encode(payload),
         {:ok, response} <- HTTPoison.post(url, json, headers, options) do
      case response do
        %{status_code: 200, body: body} ->
          case Jason.decode(body) do
            {:ok, decoded} -> parse_claude_response(decoded)
            {:error, reason} -> {:error, {:json_decode_error, reason}}
          end
          
        %{status_code: status, body: body} ->
          {:error, {:http_error, status, body}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp parse_claude_response(%{"content" => [%{"text" => text}]}) do
    case Jason.decode(text) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:ok, %{"summary" => text, "raw_response" => true}}
    end
  end
  
  defp parse_claude_response(response) do
    {:error, {:unexpected_response_format, response}}
  end
  
  defp default_governance_rules do
    [
      %{
        "id" => "authority_separation",
        "rule" => "Policies must clearly define authority boundaries",
        "enforcement" => "mandatory"
      },
      %{
        "id" => "change_control",
        "rule" => "All policy changes require version control and approval",
        "enforcement" => "mandatory"
      },
      %{
        "id" => "impact_assessment",
        "rule" => "High-impact policies require cross-system impact assessment",
        "enforcement" => "conditional"
      }
    ]
  end
  
  defp default_meta_policies do
    %{
      "governance_model" => "adaptive_hierarchy",
      "change_frequency" => "quarterly_review",
      "learning_integration" => "continuous",
      "decision_making" => "consensus_with_escalation",
      "performance_monitoring" => "real_time",
      "version_control" => "semantic_versioning"
    }
  end
end

# Live Test Runner
defmodule PolicyIntelligenceLiveTest do
  def run do
    IO.puts("🧠 S5 Policy Intelligence Engine - Live Test")
    IO.puts(String.duplicate("=", 70))
    
    api_key = "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"
    
    case Cybernetic.VSM.System5.PolicyIntelligence.new(api_key: api_key) do
      {:ok, engine} ->
        IO.puts("✅ Policy Intelligence Engine initialized")
        IO.puts("")
        
        run_policy_evolution_test(engine)
        IO.puts("")
        
        run_governance_recommendation_test(engine)
        IO.puts("")
        
        run_meta_policy_evolution_test(engine)
        IO.puts("")
        
        run_system_alignment_test(engine)
        
      {:error, reason} ->
        IO.puts("❌ Failed to initialize engine: #{inspect(reason)}")
    end
  end
  
  defp run_policy_evolution_test(engine) do
    IO.puts("📊 TEST 1: Policy Evolution Analysis")
    IO.puts(String.duplicate("-", 40))
    
    context = %{
      policy_id: "security_access_control_v2",
      domain: "security_governance",
      current_version: "2.3",
      last_review: "2024-06-15",
      performance_metrics: %{
        compliance_rate: 0.94,
        incident_reduction: 0.67,
        user_satisfaction: 0.81,
        implementation_cost: "medium"
      },
      change_history: [
        %{version: "2.0", change: "Added MFA requirement", impact: "high"},
        %{version: "2.1", change: "Simplified approval workflow", impact: "medium"},
        %{version: "2.2", change: "Integrated with SSO", impact: "low"},
        %{version: "2.3", change: "Added role-based exceptions", impact: "medium"}
      ],
      business_context: %{
        regulatory_changes: ["GDPR update", "SOC2 Type II"],
        market_pressures: ["remote_work_security", "zero_trust_adoption"],
        organizational_changes: ["team_growth", "product_expansion"]
      }
    }
    
    case Cybernetic.VSM.System5.PolicyIntelligence.analyze_policy_evolution(engine, context) do
      {:ok, analysis} ->
        IO.puts("✅ Policy evolution analysis completed")
        IO.puts("📋 Summary: #{analysis["summary"]}")
        
        if analysis["effectiveness_score"] do
          IO.puts("📈 Effectiveness Score: #{analysis["effectiveness_score"]}")
        end
        
        if analysis["improvement_recommendations"] && length(analysis["improvement_recommendations"]) > 0 do
          IO.puts("💡 Key Recommendations:")
          Enum.take(analysis["improvement_recommendations"], 3)
          |> Enum.each(fn rec ->
            IO.puts("   • [#{String.upcase(rec["type"])}] #{rec["action"]}")
          end)
        end
        
        if analysis["risk_assessment"] do
          risk = analysis["risk_assessment"]
          IO.puts("⚠️  Risk Level: #{String.upcase(risk["current_risk_level"] || "medium")}")
        end
        
      {:error, reason} ->
        IO.puts("❌ Policy evolution analysis failed: #{inspect(reason)}")
    end
  end
  
  defp run_governance_recommendation_test(engine) do
    IO.puts("🏛️  TEST 2: Governance Recommendation")
    IO.puts(String.duplicate("-", 40))
    
    context = %{
      proposed_policy: %{
        "id" => "ai_ethics_framework",
        "title" => "AI Ethics and Responsible AI Framework",
        "type" => "ethics_governance",
        "scope" => "enterprise_wide",
        "authority_level" => "high",
        "requirements" => [
          "algorithmic_transparency",
          "bias_testing_mandatory",
          "human_oversight_required",
          "data_privacy_by_design"
        ],
        "enforcement" => "mandatory",
        "exceptions" => "none"
      },
      current_policies: [
        %{"id" => "data_governance", "scope" => "data_handling", "authority" => "medium"},
        %{"id" => "privacy_policy", "scope" => "personal_data", "authority" => "high"},
        %{"id" => "security_framework", "scope" => "information_security", "authority" => "high"}
      ],
      governance_rules: [
        %{"rule" => "no_conflicting_authority", "enforcement" => "strict"},
        %{"rule" => "stakeholder_approval_required", "threshold" => "high_impact"},
        %{"rule" => "implementation_feasibility", "assessment" => "required"}
      ],
      org_context: %{
        "current_ai_usage" => "machine_learning_models",
        "regulatory_environment" => "highly_regulated",
        "risk_tolerance" => "conservative",
        "implementation_capacity" => "medium"
      }
    }
    
    case Cybernetic.VSM.System5.PolicyIntelligence.recommend_governance(engine, context) do
      {:ok, recommendations} ->
        IO.puts("✅ Governance analysis completed")
        IO.puts("📋 Summary: #{recommendations["summary"]}")
        IO.puts("🎯 Recommendation: #{String.upcase(recommendations["approval_recommendation"] || "review")}")
        
        if recommendations["conflicts_detected"] && length(recommendations["conflicts_detected"]) > 0 do
          IO.puts("⚠️  Conflicts Detected:")
          Enum.take(recommendations["conflicts_detected"], 2)
          |> Enum.each(fn conflict ->
            IO.puts("   • #{conflict["type"]}: #{conflict["description"]}")
          end)
        end
        
        if recommendations["implementation_risks"] && length(recommendations["implementation_risks"]) > 0 do
          IO.puts("🚨 Implementation Risks:")
          Enum.take(recommendations["implementation_risks"], 2)
          |> Enum.each(fn risk ->
            IO.puts("   • #{risk["risk"]} (#{risk["probability"]}/#{risk["impact"]})")
          end)
        end
        
      {:error, reason} ->
        IO.puts("❌ Governance recommendation failed: #{inspect(reason)}")
    end
  end
  
  defp run_meta_policy_evolution_test(engine) do
    IO.puts("🔄 TEST 3: Meta-Policy Evolution")
    IO.puts(String.duplicate("-", 40))
    
    context = %{
      current_meta_policies: %{
        "policy_creation_process" => "committee_review",
        "change_approval_threshold" => "majority_vote",
        "version_control_strategy" => "semantic_versioning",
        "stakeholder_engagement" => "quarterly_reviews",
        "performance_measurement" => "annual_assessment"
      },
      system_metrics: %{
        "policy_creation_time" => %{"avg_days" => 45, "target" => 30},
        "change_implementation_rate" => 0.73,
        "stakeholder_satisfaction" => 0.68,
        "compliance_effectiveness" => 0.89,
        "organizational_agility" => 0.71
      },
      historical_data: %{
        "policy_changes_per_quarter" => [12, 18, 23, 19],
        "implementation_success_rate" => [0.81, 0.75, 0.73, 0.78],
        "stakeholder_feedback_trends" => "declining_satisfaction",
        "regulatory_change_frequency" => "increasing"
      },
      challenges: [
        "slow_policy_adaptation",
        "stakeholder_engagement_fatigue", 
        "complex_approval_processes",
        "insufficient_change_communication"
      ]
    }
    
    case Cybernetic.VSM.System5.PolicyIntelligence.evolve_meta_policies(engine, context) do
      {:ok, evolution} ->
        IO.puts("✅ Meta-policy evolution completed")
        IO.puts("📋 Summary: #{evolution["summary"]}")
        
        if evolution["current_effectiveness"] do
          IO.puts("📊 Current Effectiveness: #{evolution["current_effectiveness"]}")
        end
        
        if evolution["organizational_maturity"] do
          maturity = evolution["organizational_maturity"]
          IO.puts("🎯 Maturity Level: #{String.upcase(maturity["current_level"] || "adaptive")}")
        end
        
        if evolution["learning_insights"] && length(evolution["learning_insights"]) > 0 do
          IO.puts("🧠 Key Learning Insights:")
          Enum.take(evolution["learning_insights"], 2)
          |> Enum.each(fn insight ->
            IO.puts("   • #{insight["insight"]}")
          end)
        end
        
        if evolution["system_coherence_score"] do
          IO.puts("🔗 System Coherence: #{evolution["system_coherence_score"]}")
        end
        
      {:error, reason} ->
        IO.puts("❌ Meta-policy evolution failed: #{inspect(reason)}")
    end
  end
  
  defp run_system_alignment_test(engine) do
    IO.puts("🎯 TEST 4: System Alignment Assessment")
    IO.puts(String.duplicate("-", 40))
    
    context = %{
      s1_policies: [
        %{"id" => "operational_sla", "focus" => "performance", "metrics" => ["uptime", "latency"]},
        %{"id" => "worker_management", "focus" => "resource", "scope" => "capacity_planning"}
      ],
      s2_policies: [
        %{"id" => "coordination_protocol", "focus" => "workflow", "scope" => "cross_team"},
        %{"id" => "conflict_resolution", "focus" => "dispute", "scope" => "inter_system"}
      ],
      s3_policies: [
        %{"id" => "monitoring_framework", "focus" => "oversight", "scope" => "system_wide"},
        %{"id" => "intervention_rules", "focus" => "control", "scope" => "automated_response"}
      ],
      s4_policies: [
        %{"id" => "intelligence_gathering", "focus" => "analysis", "scope" => "predictive"},
        %{"id" => "learning_framework", "focus" => "adaptation", "scope" => "continuous"}
      ],
      s5_policies: [
        %{"id" => "governance_charter", "focus" => "meta", "scope" => "organizational"},
        %{"id" => "strategic_direction", "focus" => "vision", "scope" => "long_term"}
      ],
      org_context: %{
        "organizational_structure" => "matrix_hybrid",
        "decision_making_style" => "collaborative_hierarchical",
        "change_management_maturity" => "developing",
        "stakeholder_diversity" => "high"
      }
    }
    
    case Cybernetic.VSM.System5.PolicyIntelligence.assess_system_alignment(engine, context) do
      {:ok, alignment} ->
        IO.puts("✅ System alignment assessment completed")
        IO.puts("📋 Summary: #{alignment["summary"]}")
        
        if alignment["overall_alignment_score"] do
          score = alignment["overall_alignment_score"]
          IO.puts("🎯 Overall Alignment Score: #{score} (#{alignment_rating(score)})")
        end
        
        if alignment["system_scores"] do
          IO.puts("📊 System Scores:")
          alignment["system_scores"]
          |> Enum.each(fn {system, score} ->
            IO.puts("   • #{String.upcase(system)}: #{score}")
          end)
        end
        
        if alignment["conflicts"] && length(alignment["conflicts"]) > 0 do
          IO.puts("⚠️  Policy Conflicts:")
          Enum.take(alignment["conflicts"], 2)
          |> Enum.each(fn conflict ->
            systems = Enum.join(conflict["systems"] || [], ", ")
            IO.puts("   • #{systems}: #{conflict["description"]}")
          end)
        end
        
        if alignment["synergy_opportunities"] && length(alignment["synergy_opportunities"]) > 0 do
          IO.puts("✨ Synergy Opportunities:")
          Enum.take(alignment["synergy_opportunities"], 2)
          |> Enum.each(fn synergy ->
            systems = Enum.join(synergy["systems"] || [], "-")
            IO.puts("   • #{systems}: #{synergy["opportunity"]}")
          end)
        end
        
      {:error, reason} ->
        IO.puts("❌ System alignment assessment failed: #{inspect(reason)}")
    end
    
    IO.puts("")
    IO.puts("🎉 Policy Intelligence Engine live test completed!")
  end
  
  defp alignment_rating(score) when score >= 0.9, do: "Excellent"
  defp alignment_rating(score) when score >= 0.8, do: "Good"
  defp alignment_rating(score) when score >= 0.7, do: "Fair"
  defp alignment_rating(_), do: "Needs Improvement"
end

# Run the live test
PolicyIntelligenceLiveTest.run()