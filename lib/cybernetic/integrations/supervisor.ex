defmodule Cybernetic.Integrations.Supervisor do
  @moduledoc """
  Supervisor for integration services.

  Manages:
  - Integration registry (for per-tenant process lookup)
  - Global integration services
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Registry for per-tenant integration processes
      {Registry, keys: :unique, name: Cybernetic.Integrations.Registry},

      # Global integration services can be added here
      # e.g., {Cybernetic.Integrations.MetricsAggregator, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Start integration services for a tenant.
  """
  def start_tenant_integrations(tenant_id, opts \\ []) do
    children = [
      {Cybernetic.Integrations.OhMyOpencode.VSMBridge, Keyword.put(opts, :tenant_id, tenant_id)},
      {Cybernetic.Integrations.OhMyOpencode.EventBridge, Keyword.put(opts, :tenant_id, tenant_id)},
      {Cybernetic.Integrations.OhMyOpencode.ContextGraph, Keyword.put(opts, :tenant_id, tenant_id)}
    ]

    # Start each child under the main application supervisor
    # In production, you might want a per-tenant DynamicSupervisor
    Enum.map(children, fn child_spec ->
      DynamicSupervisor.start_child(Cybernetic.DynamicSupervisor, child_spec)
    end)
  end

  @doc """
  Stop integration services for a tenant.
  """
  def stop_tenant_integrations(tenant_id) do
    modules = [
      Cybernetic.Integrations.OhMyOpencode.VSMBridge,
      Cybernetic.Integrations.OhMyOpencode.EventBridge,
      Cybernetic.Integrations.OhMyOpencode.ContextGraph
    ]

    Enum.each(modules, fn module ->
      case Registry.lookup(Cybernetic.Integrations.Registry, {module, tenant_id}) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(Cybernetic.DynamicSupervisor, pid)

        [] ->
          :ok
      end
    end)
  end
end
