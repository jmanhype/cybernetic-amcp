defmodule Cybernetic.Intelligence.Policy.PipelineTest do
  use ExUnit.Case, async: false

  alias Cybernetic.Intelligence.Policy.Pipeline

  @eval_context %{
    context: %{authenticated: true, roles: [:editor], user_id: "user_123"},
    resource: %{owner_id: "user_123", status: :draft},
    action: :edit,
    environment: %{}
  }

  setup do
    start_supervised!(Pipeline)
    :ok
  end

  test "registers and evaluates a policy" do
    policy_id = "p_" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, 1} = Pipeline.register(policy_id, "require :authenticated\nallow")
    assert :allow = Pipeline.evaluate(policy_id, @eval_context)

    context = put_in(@eval_context[:context][:authenticated], false)
    assert :deny = Pipeline.evaluate(policy_id, context)
  end

  test "supports versioning and rollback" do
    policy_id = "p_" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, 1} = Pipeline.register(policy_id, "allow")
    assert :allow = Pipeline.evaluate(policy_id, @eval_context)

    assert {:ok, 2} = Pipeline.register(policy_id, "deny")
    assert :deny = Pipeline.evaluate(policy_id, @eval_context)

    assert :ok = Pipeline.set_active_version(policy_id, 1)
    assert :allow = Pipeline.evaluate(policy_id, @eval_context)
  end
end
