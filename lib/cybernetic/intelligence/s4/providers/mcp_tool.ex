defmodule Cybernetic.Intelligence.S4.Providers.MCPTool do
  @moduledoc """
  LLM provider that forwards prompts to an MCP tool (e.g., 'llm_completion').
  """
  @behaviour Cybernetic.Intelligence.S4.Providers.LLMProvider

  alias Cybernetic.Core.MCP.Hermes.Registry

  @impl true
  def complete(prompt, opts) do
    tool = opts[:tool] || "llm_completion"
    with {:ok, %{impl: impl}} <- Registry.get_tool(tool),
         {:ok, result} <- impl.invoke(%{"prompt" => prompt, "model" => opts[:model]}) do
      {:ok, result["text"] || result["output"] || Jason.encode!(result)}
    else
      other -> {:error, other}
    end
  end
end