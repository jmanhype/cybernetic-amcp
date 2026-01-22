defmodule Cybernetic.Archeology.Overlay do
  @moduledoc """
  Static-Dynamic Overlay Analysis.

  Correlates static analysis results (from archeology) with dynamic execution traces
  to identify dead code, ghost paths, and coverage metrics.

  ## Data Normalization

  Both static functions and dynamic spans are normalized to a unified format:
  `{module_string, function_string, arity}`

  This allows efficient set operations to identify:
  - Dead code: static functions never appearing in dynamic traces
  - Ghost paths: dynamic spans without corresponding static calls
  - Coverage: percentage of static code exercised per module
  """

  require Logger

  @type static_function :: %{
          module: String.t(),
          function: String.t(),
          arity: non_neg_integer(),
          file: String.t(),
          line: non_neg_integer(),
          type: String.t()
        }

  @type dynamic_span :: %{
          module: String.t(),
          function: String.t(),
          arity: non_neg_integer(),
          file: String.t(),
          line: non_neg_integer(),
          timestamp: pos_integer(),
          duration_us: non_neg_integer(),
          metadata: map()
        }

  @type normalized_key :: {String.t(), String.t(), non_neg_integer()}

  @doc """
  Loads static analysis data from archeology-results.json.

  Returns a map with traces and orphan_functions.
  """
  @spec load_static_data(String.t()) :: %{traces: [map()], orphan_functions: [map()]}
  def load_static_data(path) do
    Logger.debug("Loading static data from #{path}")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            Logger.debug("Loaded static data: #{length(data["traces"])} traces")
            data

          {:error, reason} ->
            raise "Failed to decode #{path}: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "Failed to read #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Loads dynamic trace data from dynamic-traces.json.

  Returns a map with traces.
  """
  @spec load_dynamic_data(String.t()) :: %{traces: [map()]}
  def load_dynamic_data(path) do
    Logger.debug("Loading dynamic data from #{path}")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            Logger.debug("Loaded dynamic data: #{length(data["traces"])} traces")
            data

          {:error, reason} ->
            raise "Failed to decode #{path}: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "Failed to read #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Normalizes static functions from archeology traces into a MapSet.

  Extracts unique {module, function, arity} tuples from all trace functions.
  """
  @spec normalize_static_functions(map()) :: MapSet.t(normalized_key())
  def normalize_static_functions(static_data) do
    static_data["traces"]
    |> Enum.flat_map(fn trace -> trace["functions"] end)
    |> Enum.filter(fn fn_ref ->
      # Filter out unknown type functions (., ::, etc.)
      fn_ref["type"] != "unknown"
    end)
    |> Enum.map(fn fn_ref ->
      {fn_ref["module"], fn_ref["function"], fn_ref["arity"]}
    end)
    |> MapSet.new()
  end

  @doc """
  Normalizes dynamic spans from dynamic traces into a MapSet.

  Extracts unique {module, function, arity} tuples from all spans.
  """
  @spec normalize_dynamic_spans(map()) :: MapSet.t(normalized_key())
  def normalize_dynamic_spans(dynamic_data) do
    dynamic_data["traces"]
    |> Enum.flat_map(fn trace -> trace["spans"] end)
    |> Enum.map(fn span ->
      {span["module"], span["function"], span["arity"]}
    end)
    |> MapSet.new()
  end

  @doc """
  Groups static functions by module for coverage analysis.

  Returns a map where keys are module names and values are lists of function references.
  """
  @spec group_static_functions_by_module(map()) :: %{String.t() => [static_function()]}
  def group_static_functions_by_module(static_data) do
    static_data["traces"]
    |> Enum.flat_map(fn trace -> trace["functions"] end)
    |> Enum.filter(fn fn_ref ->
      # Filter out unknown type functions
      fn_ref["type"] != "unknown"
    end)
    |> Enum.group_by(fn fn_ref -> fn_ref["module"] end)
  end

  @doc """
  Groups dynamic spans by module and counts executions.

  Returns a map where keys are module names and values are maps with
  function keys and execution counts.
  """
  @spec group_dynamic_spans_by_module(map()) :: %{String.t() => %{normalized_key() => pos_integer()}}
  def group_dynamic_spans_by_module(dynamic_data) do
    dynamic_data["traces"]
    |> Enum.flat_map(fn trace -> trace["spans"] end)
    |> Enum.reduce(%{}, fn span, acc ->
      module = span["module"]
      key = {module, span["function"], span["arity"]}

      Map.update(acc, module, %{key => 1}, fn module_map ->
        Map.update(module_map, key, 1, &(&1 + 1))
      end)
    end)
  end

  @doc """
  Detects dead code - static functions that never appear in dynamic traces.

  Filters out test functions and callback functions to reduce false positives.
  Returns a list of static function references with metadata.
  """
  @spec detect_dead_code(map(), map()) :: [static_function()]
  def detect_dead_code(static_data, dynamic_data) do
    Logger.debug("Detecting dead code...")

    static_functions = normalize_static_functions(static_data)
    dynamic_functions = normalize_dynamic_spans(dynamic_data)

    # Compute set difference: static - dynamic
    dead_code_keys = MapSet.difference(static_functions, dynamic_functions)

    Logger.debug("Found #{MapSet.size(dead_code_keys)} potential dead code functions")

    # Get full function references for dead code
    all_functions =
      static_data["traces"]
      |> Enum.flat_map(fn trace -> trace["functions"] end)
      |> Enum.filter(fn fn_ref -> fn_ref["type"] != "unknown" end)

    # Filter to dead code and apply exclusions
    all_functions
    |> Enum.filter(fn fn_ref ->
      key = {fn_ref["module"], fn_ref["function"], fn_ref["arity"]}
      MapSet.member?(dead_code_keys, key)
    end)
    |> Enum.reject(fn fn_ref -> is_test_function?(fn_ref) end)
    |> Enum.reject(fn fn_ref -> is_callback_function?(fn_ref) end)
    |> Enum.sort_by(fn fn_ref -> {fn_ref["module"], fn_ref["function"], fn_ref["arity"]} end)
  end

  @doc """
  Checks if a function reference is a test function.

  Test functions are identified by module name ending with "Test" or
  function name starting with "test_".
  """
  @spec is_test_function?(static_function() | dynamic_span()) :: boolean()
  def is_test_function?(fn_ref) do
    module_name = fn_ref["module"]
    function_name = fn_ref["function"]

    # Check if module name ends with "Test" (case-sensitive, avoiding false positives)
    String.ends_with?(module_name, "Test") or
      # Check if function name starts with "test_" (common Elixir convention)
      String.starts_with?(function_name, "test_")
  end

  @doc """
  Checks if a function reference is a callback function.

  Callback functions are standard OTP callbacks for GenServer, GenStage, etc.
  """
  @spec is_callback_function?(static_function() | dynamic_span()) :: boolean()
  def is_callback_function?(fn_ref) do
    callbacks = [
      "init", "handle_call", "handle_cast", "handle_info", "terminate", "code_change",
      "handle_continue", "format_status", "handle_debug",
      "start_link", "child_spec", "post_init",
      "handle_events", "handle_subscription", "cancellable?",
      "perform", "timeout", "retry_at",
      "call", "stream", "crawl"
    ]

    fn_ref["function"] in callbacks
  end
end
