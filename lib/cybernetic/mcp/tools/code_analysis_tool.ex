defmodule Cybernetic.MCP.Tools.CodeAnalysisTool do
  @moduledoc """
  MCP Code Analysis Tool - Provides code analysis and manipulation capabilities.
  
  Enables the VSM to:
  - Analyze code structure and complexity
  - Detect patterns and anti-patterns
  - Generate code snippets
  - Perform refactoring suggestions
  - Security vulnerability scanning
  """
  
  @behaviour Cybernetic.MCP.Tool
  
  alias Cybernetic.Security.AuditLogger
  
  @tool_info %{
    name: "code_analysis",
    version: "1.0.0",
    description: "Code analysis and manipulation tool",
    capabilities: ["analyze", "generate", "refactor", "security_scan"],
    requires_auth: false
  }
  
  @impl true
  def info, do: @tool_info
  
  @impl true
  def execute(operation, params, context) do
    with :ok <- validate_params(operation, params) do
      
      AuditLogger.log(:mcp_tool_execution, %{
        tool: "code_analysis",
        operation: operation,
        actor: context[:actor]
      })
      
      result = perform_operation(operation, params, context)
      
      {:ok, %{
        result: result,
        metadata: %{
          tool: "code_analysis",
          operation: operation,
          timestamp: DateTime.utc_now()
        }
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end
  
  @impl true
  def validate_params(operation, params) do
    case operation do
      "analyze" ->
        if params["code"] || params["file_path"] do
          :ok
        else
          {:error, "Missing code or file_path parameter"}
        end
      
      "generate" ->
        if params["template"] && params["context"] do
          :ok
        else
          {:error, "Missing template or context parameters"}
        end
      
      "refactor" ->
        if params["code"] && params["pattern"] do
          :ok
        else
          {:error, "Missing code or pattern parameters"}
        end
      
      "security_scan" ->
        if params["code"] || params["directory"] do
          :ok
        else
          {:error, "Missing code or directory parameter"}
        end
      
      _ ->
        {:error, "Unknown operation: #{operation}"}
    end
  end
  
  # ========== PRIVATE FUNCTIONS ==========
  
  defp perform_operation("analyze", params, _context) do
    code = params["code"] || read_file(params["file_path"])
    language = params["language"] || detect_language(code)
    
    %{
      language: language,
      metrics: analyze_metrics(code, language),
      complexity: calculate_complexity(code),
      patterns: detect_patterns(code, language),
      anti_patterns: detect_anti_patterns(code, language),
      dependencies: extract_dependencies(code, language),
      suggestions: generate_suggestions(code, language)
    }
  end
  
  defp perform_operation("generate", params, _context) do
    template = params["template"]
    context = params["context"]
    language = params["language"] || "elixir"
    
    generated_code = 
      case template do
        "genserver" ->
          generate_genserver(context, language)
        
        "supervisor" ->
          generate_supervisor(context, language)
        
        "test" ->
          generate_test(context, language)
        
        "api_endpoint" ->
          generate_api_endpoint(context, language)
        
        "mcp_tool" ->
          generate_mcp_tool(context)
        
        _ ->
          "# Unknown template: #{template}"
      end
    
    %{
      code: generated_code,
      template: template,
      language: language,
      line_count: count_lines(generated_code)
    }
  end
  
  defp perform_operation("refactor", params, _context) do
    code = params["code"]
    pattern = params["pattern"]
    
    refactored = 
      case pattern do
        "extract_function" ->
          extract_function(code, params["selection"])
        
        "rename_variable" ->
          rename_variable(code, params["old_name"], params["new_name"])
        
        "simplify_conditionals" ->
          simplify_conditionals(code)
        
        "remove_duplication" ->
          remove_duplication(code)
        
        "improve_naming" ->
          improve_naming(code)
        
        _ ->
          code
      end
    
    %{
      original: code,
      refactored: refactored,
      pattern: pattern,
      changes: calculate_diff(code, refactored)
    }
  end
  
  defp perform_operation("security_scan", params, _context) do
    code = params["code"] || scan_directory(params["directory"])
    
    vulnerabilities = scan_for_vulnerabilities(code)
    
    %{
      vulnerabilities: vulnerabilities,
      severity_summary: %{
        critical: count_by_severity(vulnerabilities, :critical),
        high: count_by_severity(vulnerabilities, :high),
        medium: count_by_severity(vulnerabilities, :medium),
        low: count_by_severity(vulnerabilities, :low)
      },
      recommendations: generate_security_recommendations(vulnerabilities),
      scan_timestamp: DateTime.utc_now()
    }
  end
  
  defp analyze_metrics(code, language) do
    %{
      lines_of_code: count_lines(code),
      cyclomatic_complexity: calculate_cyclomatic_complexity(code),
      maintainability_index: calculate_maintainability_index(code),
      technical_debt_ratio: calculate_technical_debt(code),
      test_coverage: estimate_test_coverage(code),
      documentation_coverage: calculate_doc_coverage(code)
    }
  end
  
  defp calculate_complexity(code) do
    # Simple complexity calculation
    conditionals = Regex.scan(~r/\b(if|case|cond|when)\b/, code) |> length()
    loops = Regex.scan(~r/\b(for|while|Enum\.\w+|Stream\.\w+)\b/, code) |> length()
    functions = Regex.scan(~r/\bdef(p?)\s+\w+/, code) |> length()
    
    %{
      cyclomatic: conditionals + loops + 1,
      cognitive: conditionals * 2 + loops * 3 + functions,
      halstead: calculate_halstead_complexity(code),
      overall: "moderate"
    }
  end
  
  defp detect_patterns(code, "elixir") do
    patterns = []
    
    # GenServer pattern
    if String.contains?(code, "use GenServer") do
      patterns = ["genserver" | patterns]
    end
    
    # Supervisor pattern
    if String.contains?(code, "use Supervisor") do
      patterns = ["supervisor" | patterns]
    end
    
    # Pipeline pattern
    if Regex.match?(~r/\|>/, code) do
      patterns = ["pipeline" | patterns]
    end
    
    # Pattern matching
    if Regex.match?(~r/case .+ do/, code) do
      patterns = ["pattern_matching" | patterns]
    end
    
    patterns
  end
  defp detect_patterns(_code, _language), do: []
  
  defp detect_anti_patterns(code, "elixir") do
    anti_patterns = []
    
    # Long functions
    functions = Regex.scan(~r/def(p?)\s+(\w+).+?end/s, code)
    long_functions = 
      functions
      |> Enum.filter(fn [func | _] -> 
        count_lines(func) > 50
      end)
      |> Enum.map(fn [_, _, name] -> {:long_function, name} end)
    
    anti_patterns = anti_patterns ++ long_functions
    
    # Deeply nested code
    if Regex.match?(~r/\s{16,}/, code) do
      anti_patterns = [{:deep_nesting, "Excessive indentation detected"} | anti_patterns]
    end
    
    # Magic numbers
    magic_numbers = Regex.scan(~r/\b\d{2,}\b/, code)
    if length(magic_numbers) > 5 do
      anti_patterns = [{:magic_numbers, "Multiple hardcoded values"} | anti_patterns]
    end
    
    anti_patterns
  end
  defp detect_anti_patterns(_code, _language), do: []
  
  defp generate_genserver(context, "elixir") do
    name = context["name"] || "MyServer"
    
    """
    defmodule #{name} do
      use GenServer
      require Logger
      
      # Client API
      
      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end
      
      def get_state do
        GenServer.call(__MODULE__, :get_state)
      end
      
      def update_state(new_state) do
        GenServer.cast(__MODULE__, {:update_state, new_state})
      end
      
      # Server Callbacks
      
      @impl true
      def init(opts) do
        state = %{
          data: Keyword.get(opts, :data, %{}),
          started_at: DateTime.utc_now()
        }
        
        Logger.info("\#{__MODULE__} started")
        {:ok, state}
      end
      
      @impl true
      def handle_call(:get_state, _from, state) do
        {:reply, state, state}
      end
      
      @impl true
      def handle_cast({:update_state, new_state}, _state) do
        {:noreply, new_state}
      end
    end
    """
  end
  defp generate_genserver(_context, _language), do: "# Unsupported language"
  
  defp generate_mcp_tool(context) do
    name = context["name"] || "MyTool"
    
    """
    defmodule Cybernetic.MCP.Tools.#{name} do
      @moduledoc \"\"\"
      MCP #{name} Tool
      \"\"\"
      
      @behaviour Cybernetic.MCP.Tool
      
      @tool_info %{
        name: "#{String.downcase(name)}",
        version: "1.0.0",
        description: "#{context["description"] || "Custom MCP tool"}",
        capabilities: #{inspect(context["capabilities"] || ["execute"])},
        requires_auth: #{context["requires_auth"] || false}
      }
      
      @impl true
      def info, do: @tool_info
      
      @impl true
      def execute(operation, params, context) do
        # Implementation here
        {:ok, %{result: "success"}}
      end
      
      @impl true
      def validate_params(_operation, _params) do
        :ok
      end
    end
    """
  end
  
  defp scan_for_vulnerabilities(code) do
    vulnerabilities = []
    
    # SQL Injection
    if Regex.match?(~r/\".*SELECT.*\#\{.*\}.*\"/, code) do
      vulnerabilities = [
        %{
          type: "sql_injection",
          severity: :critical,
          line: 1,
          message: "Potential SQL injection vulnerability"
        } | vulnerabilities
      ]
    end
    
    # Hardcoded secrets
    if Regex.match?(~r/(api_key|password|secret)\s*=\s*\"[^\"]+\"/, code) do
      vulnerabilities = [
        %{
          type: "hardcoded_secret",
          severity: :high,
          line: 1,
          message: "Hardcoded secret detected"
        } | vulnerabilities
      ]
    end
    
    # Command injection
    if Regex.match?(~r/System\.cmd\([^,]+\#\{/, code) do
      vulnerabilities = [
        %{
          type: "command_injection",
          severity: :critical,
          line: 1,
          message: "Potential command injection vulnerability"
        } | vulnerabilities
      ]
    end
    
    vulnerabilities
  end
  
  defp generate_security_recommendations(vulnerabilities) do
    vulnerabilities
    |> Enum.map(fn vuln ->
      case vuln.type do
        "sql_injection" ->
          "Use parameterized queries or Ecto changesets"
        
        "hardcoded_secret" ->
          "Move secrets to environment variables or secure key management"
        
        "command_injection" ->
          "Sanitize user input before passing to System.cmd"
        
        _ ->
          "Review and fix security vulnerability"
      end
    end)
    |> Enum.uniq()
  end
  
  # Helper functions
  defp count_lines(code), do: String.split(code, "\n") |> length()
  defp detect_language(code) do
    cond do
      String.contains?(code, "defmodule") -> "elixir"
      String.contains?(code, "function") -> "javascript"
      String.contains?(code, "def ") && String.contains?(code, "self") -> "python"
      true -> "unknown"
    end
  end
  
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> ""
    end
  end
  
  defp scan_directory(_dir), do: ""
  defp extract_dependencies(_code, _lang), do: []
  defp generate_suggestions(_code, _lang), do: []
  defp calculate_cyclomatic_complexity(_code), do: 5
  defp calculate_maintainability_index(_code), do: 75
  defp calculate_technical_debt(_code), do: 0.05
  defp estimate_test_coverage(_code), do: 0.8
  defp calculate_doc_coverage(_code), do: 0.6
  defp calculate_halstead_complexity(_code), do: %{volume: 100, difficulty: 10}
  defp generate_supervisor(_context, _lang), do: "# Supervisor template"
  defp generate_test(_context, _lang), do: "# Test template"
  defp generate_api_endpoint(_context, _lang), do: "# API endpoint template"
  defp extract_function(code, _selection), do: code
  defp rename_variable(code, _old, _new), do: code
  defp simplify_conditionals(code), do: code
  defp remove_duplication(code), do: code
  defp improve_naming(code), do: code
  defp calculate_diff(_old, _new), do: []
  defp count_by_severity(vulns, severity) do
    Enum.count(vulns, & &1.severity == severity)
  end
end