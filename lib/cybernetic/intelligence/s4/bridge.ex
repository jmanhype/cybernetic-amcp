defmodule Cybernetic.Intelligence.S4.Bridge do
  @moduledoc """
  System-4: consumes Central Aggregator facts, queries an LLM, emits SOP proposals.

  Input  : [:cybernetic, :aggregator, :facts] telemetry events
  Output : [:cybernetic, :s4, :analysis] with structured results
  """
  use GenServer
  require Logger

  alias Cybernetic.Intelligence.S4.Providers.MCPTool
  alias Cybernetic.Intelligence.S4.Prompts.Schemas

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    provider = opts[:provider] || MCPTool
    :telemetry.attach_many(
      {__MODULE__, :facts},
      [[:cybernetic, :aggregator, :facts]],
      &__MODULE__.handle_fact/4,
      %{provider: provider, provider_opts: opts[:provider_opts] || []}
    )

    {:ok, %{provider: provider, provider_opts: opts[:provider_opts] || []}}
  end

  @doc false
  def handle_fact(_event, measurements, meta, %{provider: provider, provider_opts: p_opts}) do
    observations = %{
      window: meta[:window] || "1m",
      facts: measurements[:facts] || []
    }

    prompt = Schemas.policy_gap_prompt(observations)
    case provider.complete(prompt, p_opts) do
      {:ok, text} ->
        :telemetry.execute([:cybernetic, :s4, :analysis], %{ok: 1}, %{raw: text})
        # Optionally forward to SOP engine
        if Process.whereis(Cybernetic.Intelligence.S4.SOPEngine) do
          send(Cybernetic.Intelligence.S4.SOPEngine, {:s4_output, text})
        end
      {:error, reason} ->
        Logger.warning("S4 LLM error: #{inspect(reason)}")
        :telemetry.execute([:cybernetic, :s4, :analysis], %{error: 1}, %{reason: reason})
    end
  end
end