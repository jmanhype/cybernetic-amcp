
defmodule Cybernetic.MCP.HermesClient do
  @moduledoc """
  Real Hermes MCP client implementation for Cybernetic VSM.
  Provides access to external MCP tools and capabilities using the Hermes library.
  """
  use Hermes.Client,
    name: "Cybernetic",
    version: "0.1.0",
    protocol_version: "2024-11-05"

  require Logger
  
  @behaviour Cybernetic.Plugin

  @impl true
  def process(%{tool: tool, params: params}, state) do
    Logger.debug("Hermes MCP tool call: #{tool} with #{inspect(params)}")
    
    case call_tool(tool, params, timeout: 30_000) do
      {:ok, %{is_error: false, result: result}} ->
        {:ok, %{tool: tool, result: result, success: true}, state}
      
      {:ok, %{is_error: true, result: error}} ->
        Logger.warning("Hermes MCP tool error: #{inspect(error)}")
        {:error, %{tool: tool, error: :tool_error, message: error["message"]}, state}
      
      {:error, reason} ->
        Logger.warning("Hermes MCP call failed: #{inspect(reason)}")
        {:error, %{tool: tool, error: :client_error, reason: reason}, state}
    end
  rescue
    error ->
      Logger.error("Hermes MCP client error: #{inspect(error)}")
      {:error, %{tool: tool, error: :client_error, details: inspect(error)}, state}
  end

  @impl true
  def metadata(), do: %{name: "hermes_mcp", version: "0.1.0"}

  @impl true
  def handle_event(event, state) do
    Logger.debug("Hermes MCP client received event: #{inspect(event)}")
    {:ok, state}
  end

  @doc """
  Check connection status and available tools.
  """
  def health_check do
    try do
      case ping() do
        :pong ->
          {:ok, %{result: %{"tools" => tools}}} = list_tools()
          {:ok, %{status: :healthy, tools_count: length(tools)}}
        
        {:error, reason} ->
          {:error, %{status: :unhealthy, reason: reason}}
      end
    rescue
      error ->
        {:error, %{status: :error, error: inspect(error)}}
    end
  end

  @doc """
  Get available tools from the MCP server.
  """
  def get_available_tools do
    case list_tools() do
      {:ok, %{result: %{"tools" => tools}}} ->
        formatted_tools = Enum.map(tools, fn tool ->
          %{
            name: tool["name"],
            description: tool["description"],
            input_schema: tool["inputSchema"]
          }
        end)
        {:ok, formatted_tools}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute an MCP tool with progress tracking.
  """
  def execute_tool(tool_name, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    progress_callback = Keyword.get(opts, :progress_callback)
    
    call_opts = [timeout: timeout]
    call_opts = if progress_callback do
      progress_token = Hermes.MCP.ID.generate_progress_token()
      [{:progress, [token: progress_token, callback: progress_callback]} | call_opts]
    else
      call_opts
    end
    
    case call_tool(tool_name, params, call_opts) do
      {:ok, %{is_error: false, result: result}} ->
        {:ok, result}
      
      {:ok, %{is_error: true, result: error}} ->
        {:error, %{type: :tool_error, message: error["message"]}}
      
      {:error, reason} ->
        {:error, %{type: :client_error, reason: reason}}
    end
  end
end
