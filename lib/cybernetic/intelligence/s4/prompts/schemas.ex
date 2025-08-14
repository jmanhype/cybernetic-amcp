defmodule Cybernetic.Intelligence.S4.Prompts.Schemas do
  @moduledoc false

  def policy_gap_prompt(observations) do
    """
    You are the System-4 policy analyst. Given these observations (JSON):

    #{Jason.encode!(observations, pretty: true)}

    • Identify policy gaps and SOP misalignments.
    • Suggest concrete SOP updates.
    • Output JSON with fields: issues[], sop_updates[], risk_score (0..100).
    """
  end
end