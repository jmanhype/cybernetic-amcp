defmodule Cybernetic.VSM.System5.PolicyIntelligenceScorersTest do
  @moduledoc """
  IP-32 special-bar tests: PolicyIntelligence's non-LLM layer must
  compute from its inputs. The bar: scorer outputs VARY with real
  inputs (two metric states -> two different scores), planted
  governance violations and overlaps are found, alignment is 1.0
  only for a consistent corpus and drops by the published formula
  otherwise, missing metrics yield :insufficient_data rather than a
  constant, and the fallback evolution analysis carries no
  evolution_score (D7).

  PolicyIntelligence is started standalone: in test env the
  Anthropic provider is unavailable, so every call exercises the
  fallback (non-LLM) layer.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.VSM.System5.{Policy, PolicyIntelligence}

  setup do
    pi_pid = start_if_needed(PolicyIntelligence)
    policy_pid = start_if_needed(Policy)

    on_exit(fn ->
      for pid <- [pi_pid, policy_pid] do
        if pid && Process.alive?(pid), do: GenServer.stop(pid)
      end
    end)

    :ok
  end

  defp start_if_needed(module) do
    case Process.whereis(module) do
      nil ->
        {:ok, pid} = module.start_link([])
        pid

      _pid ->
        nil
    end
  end

  describe "meta-policy performance scoring" do
    test "two different metric states produce two different scores and adaptations" do
      assert {:ok, strong} =
               PolicyIntelligence.evolve_meta_policies(
                 %{success_rate: 1.0, denial_rate: 0.0, error_rate: 0.0},
                 %{}
               )

      assert {:ok, weak} =
               PolicyIntelligence.evolve_meta_policies(
                 %{success_rate: 0.0, denial_rate: 1.0, error_rate: 1.0},
                 %{}
               )

      assert strong.performance_score == 1.0
      assert weak.performance_score == 0.0
      assert strong.performance_score != weak.performance_score

      assert strong.confidence == 1.0
      assert weak.confidence == 1.0

      # > 0.8: learning speeds up; < 0.5: governance tightens and
      # learning halves (defaults: learning_rate 0.1, strictness
      # :medium - unless a previous test evolved the state, in
      # which case the directions still hold relative to it).
      assert strong.evolved_policies.learning_rate > weak.evolved_policies.learning_rate
      assert weak.evolved_policies.governance_strictness == :high
    end

    test "the formula matches its published weights" do
      # 0.4*0.5 + 0.3*(1-0.5) + 0.3*(1-min(0.1*5,1)) = 0.2+0.15+0.15
      assert {:ok, result} =
               PolicyIntelligence.evolve_meta_policies(
                 %{success_rate: 0.5, denial_rate: 0.5, error_rate: 0.1},
                 %{}
               )

      assert_in_delta result.performance_score, 0.5, 0.0001
      # Mid band (0.5-0.8): no adaptation pressure either way is
      # asserted on the score only; confidence is full.
      assert result.confidence == 1.0
    end

    test "partial metrics score over present inputs and report partial confidence" do
      assert {:ok, result} =
               PolicyIntelligence.evolve_meta_policies(%{"success_rate" => 0.9}, %{})

      assert_in_delta result.performance_score, 0.9, 0.0001
      assert_in_delta result.confidence, 1 / 3, 0.01
    end

    test "no metrics at all is :insufficient_data and policies are unadjusted" do
      assert {:ok, before} = PolicyIntelligence.evolve_meta_policies(%{success_rate: 0.9}, %{})
      assert is_integer(before.evolved_policies.last_evolution)

      assert {:ok, result} = PolicyIntelligence.evolve_meta_policies(%{}, %{})

      assert result.performance_score == :insufficient_data
      assert result.adaptation_reason == :insufficient_data
      assert result.confidence == 0.0
      # Unadjusted: identical to the policies the previous evolution
      # left in state (no new last_evolution stamp, no drift).
      assert result.evolved_policies == before.evolved_policies
    end
  end

  describe "governance detectors" do
    # The governance rules come from the module's own state
    # (default_governance_rules/0): no_conflicting_authority,
    # versioning_required, impact_assessment, stakeholder_approval.
    test "planted violations and overlaps are found" do
      proposed = %{
        "id" => "p-new",
        "type" => "safety",
        "rules" => %{"max_cpu" => 0.5}
        # no "version" field
      }

      current = [
        %{
          "id" => "p-old",
          "type" => "safety",
          "version" => "1.0",
          "rules" => %{"max_cpu" => 0.9}
        }
      ]

      assert {:ok, result} = PolicyIntelligence.recommend_governance(proposed, current)

      violation_rules = Enum.map(result.conflicts, & &1.rule)
      assert "versioning_required" in violation_rules
      assert "no_conflicting_authority" in violation_rules

      assert [%{policy: "p-old", conflicting_keys: ["max_cpu"]}] = result.overlaps
      assert result.approval_status == "requires_review"
      # One templated recommendation per finding.
      assert length(result.recommendations) == length(result.conflicts) + length(result.overlaps)
    end

    test "a clean proposal passes with no findings" do
      proposed = %{
        "id" => "p-new",
        "type" => "safety",
        "version" => "2.0",
        "rules" => %{"max_cpu" => 0.5}
      }

      current = [
        %{
          "id" => "p-other",
          "type" => "billing",
          "version" => "1.0",
          "rules" => %{"refund_window" => 30}
        }
      ]

      assert {:ok, result} = PolicyIntelligence.recommend_governance(proposed, current)
      assert result.conflicts == []
      assert result.overlaps == []
      assert result.approval_status == "approved"
      assert result.recommendations == []
    end

    test "cross-system scope without approval is flagged" do
      proposed = %{
        "id" => "p-wide",
        "type" => "coordination",
        "version" => "1.0",
        "scope" => "cross_system",
        "rules" => %{}
      }

      assert {:ok, result} = PolicyIntelligence.recommend_governance(proposed, [])
      assert Enum.map(result.conflicts, & &1.rule) == ["stakeholder_approval"]
    end
  end

  describe "alignment detectors" do
    test "a consistent corpus scores 1.0" do
      corpus = %{
        s1: [%{"id" => "p1", "type" => "ops-a", "rules" => %{"a" => 1}}],
        s2: [%{"id" => "p2", "type" => "ops-b", "rules" => %{"b" => 2}}],
        s3: [%{"id" => "p3", "type" => "ops-c", "rules" => %{"c" => 3}}],
        s4: [%{"id" => "p4", "type" => "ops-d", "rules" => %{"d" => 4}}],
        s5: [%{"id" => "p5", "type" => "ops-e", "rules" => %{"e" => 5}}]
      }

      assert {:ok, result} = PolicyIntelligence.assess_system_alignment(corpus)
      assert result.alignment_score == 1.0
      assert result.conflicts == []
      assert result.coverage_gaps == []
    end

    test "a planted conflict and missing systems drop the score by the formula" do
      corpus = %{
        s1: [%{"id" => "p1", "type" => "ops", "rules" => %{"max_cpu" => 0.5}}],
        s2: [%{"id" => "p2", "type" => "ops", "rules" => %{"max_cpu" => 0.9}}]
      }

      assert {:ok, result} = PolicyIntelligence.assess_system_alignment(corpus)

      assert [%{rule_key: "max_cpu", policies: ["p1", "p2"]}] = result.conflicts

      gap_systems =
        result.coverage_gaps
        |> Enum.filter(&(&1.type == :system_without_policy))
        |> Enum.map(& &1.system)

      assert Enum.sort(gap_systems) == [:s3, :s4, :s5]

      # 1 - (1*1.0 + 3*0.5) / (1 rule key + 5 systems) = 1 - 2.5/6
      assert_in_delta result.alignment_score, 1 - 2.5 / 6, 0.0001
      assert result.recommendations != []
    end

    test "an empty corpus scores 0.0, not a constant" do
      assert {:ok, result} = PolicyIntelligence.assess_system_alignment(%{})
      assert result.alignment_score == 0.0
      assert length(result.coverage_gaps) == 5
    end
  end

  describe "evolution fallback (D7)" do
    test "fallback evolution analysis carries no evolution score" do
      {:ok, _versioned} =
        Policy.put_policy("pol-scorers-1", %{
          "id" => "pol-scorers-1",
          "type" => "safety",
          "rules" => %{}
        })

      assert {:ok, analysis} =
               PolicyIntelligence.analyze_policy_evolution("pol-scorers-1", %{})

      assert analysis.evolution_score == nil
      assert analysis.evolution_score_reason == :unavailable_without_history
    end
  end
end
