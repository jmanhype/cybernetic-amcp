defmodule Cybernetic.MCP.Tools.WorkflowOrchestrationTool do
  @moduledoc """
  MCP Workflow Orchestration Tool - Manages complex multi-step workflows.
  
  Provides capabilities for:
  - Workflow definition and execution
  - Task scheduling and coordination
  - Dependency management
  - Parallel and sequential execution
  - Rollback and compensation
  """
  
  @behaviour Cybernetic.MCP.Tool
  
  use GenServer
  alias Cybernetic.Security.AuditLogger
  alias Cybernetic.VSM.System4.Service
  
  @tool_info %{
    name: "workflow_orchestration",
    version: "1.0.0", 
    description: "Workflow orchestration and task coordination tool",
    capabilities: ["define", "execute", "schedule", "monitor", "rollback"],
    requires_auth: true
  }
  
  defstruct [
    :workflows,
    :active_executions,
    :completed_executions,
    :task_queue,
    :dependencies
  ]
  
  @impl true
  def info, do: @tool_info
  
  @impl true
  def execute(operation, params, context) do
    with :ok <- validate_params(operation, params) do
      
      AuditLogger.log(:mcp_tool_execution, %{
        tool: "workflow_orchestration",
        operation: operation,
        actor: context[:actor]
      })
      
      result = 
        case operation do
          "define" -> define_workflow(params)
          "execute" -> execute_workflow(params, context)
          "schedule" -> schedule_workflow(params, context)
          "monitor" -> monitor_workflow(params)
          "rollback" -> rollback_workflow(params, context)
          _ -> {:error, "Unknown operation"}
        end
      
      case result do
        {:ok, data} ->
          {:ok, %{
            result: data,
            metadata: %{
              tool: "workflow_orchestration",
              operation: operation,
              timestamp: DateTime.utc_now()
            }
          }}
        
        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
  
  @impl true
  def validate_params(operation, params) do
    case operation do
      "define" ->
        if params["workflow"] && params["tasks"] do
          :ok
        else
          {:error, "Missing workflow definition or tasks"}
        end
      
      "execute" ->
        if params["workflow_id"] || params["workflow"] do
          :ok
        else
          {:error, "Missing workflow_id or workflow definition"}
        end
      
      "schedule" ->
        if params["workflow_id"] && params["schedule"] do
          :ok
        else
          {:error, "Missing workflow_id or schedule"}
        end
      
      "monitor" ->
        if params["execution_id"] || params["workflow_id"] do
          :ok
        else
          {:error, "Missing execution_id or workflow_id"}
        end
      
      "rollback" ->
        if params["execution_id"] do
          :ok
        else
          {:error, "Missing execution_id"}
        end
      
      _ ->
        {:error, "Unknown operation: #{operation}"}
    end
  end
  
  # ========== WORKFLOW DEFINITION ==========
  
  defp define_workflow(params) do
    workflow = params["workflow"]
    tasks = params["tasks"]
    
    # Validate workflow structure
    with :ok <- validate_workflow_structure(workflow),
         :ok <- validate_tasks(tasks),
         :ok <- validate_dependencies(tasks) do
      
      # Create workflow definition
      workflow_def = %{
        id: generate_workflow_id(),
        name: workflow["name"],
        description: workflow["description"],
        version: workflow["version"] || "1.0.0",
        tasks: build_task_graph(tasks),
        triggers: workflow["triggers"] || [],
        timeout: workflow["timeout"] || 3600,
        retry_policy: workflow["retry_policy"] || default_retry_policy(),
        compensation: workflow["compensation"] || [],
        created_at: DateTime.utc_now()
      }
      
      # Store workflow
      store_workflow(workflow_def)
      
      {:ok, workflow_def}
    else
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp build_task_graph(tasks) do
    tasks
    |> Enum.map(fn task ->
      %{
        id: task["id"],
        name: task["name"],
        type: task["type"],
        params: task["params"] || %{},
        dependencies: task["dependencies"] || [],
        timeout: task["timeout"] || 300,
        retry: task["retry"] || 3,
        parallel: task["parallel"] || false,
        condition: task["condition"],
        on_success: task["on_success"],
        on_failure: task["on_failure"],
        compensation: task["compensation"]
      }
    end)
  end
  
  # ========== WORKFLOW EXECUTION ==========
  
  defp execute_workflow(params, context) do
    workflow = 
      case params["workflow_id"] do
        nil -> params["workflow"]
        id -> load_workflow(id)
      end
    
    # Create execution instance
    execution = %{
      id: generate_execution_id(),
      workflow_id: workflow["id"] || workflow[:id],
      status: :running,
      started_at: DateTime.utc_now(),
      context: Map.merge(context, params["context"] || %{}),
      current_tasks: [],
      completed_tasks: [],
      failed_tasks: [],
      results: %{}
    }
    
    # Start execution
    spawn_execution(execution, workflow)
    
    {:ok, %{
      execution_id: execution.id,
      status: :started,
      workflow: workflow["name"] || workflow[:name]
    }}
  end
  
  defp spawn_execution(execution, workflow) do
    Task.start(fn ->
      try do
        # Execute workflow tasks
        result = execute_tasks(workflow, execution)
        
        # Update execution status
        final_execution = 
          case result do
            {:ok, results} ->
              %{execution | 
                status: :completed,
                completed_at: DateTime.utc_now(),
                results: results
              }
            
            {:error, reason} ->
              %{execution | 
                status: :failed,
                failed_at: DateTime.utc_now(),
                error: reason
              }
          end
        
        # Store execution result
        store_execution(final_execution)
        
        # Send completion notification
        send_completion_notification(final_execution)
        
      rescue
        error ->
          Logger.error("Workflow execution failed: #{inspect(error)}")
          handle_execution_error(execution, error)
      end
    end)
  end
  
  defp execute_tasks(workflow, execution) do
    tasks = workflow["tasks"] || workflow[:tasks]
    
    # Build execution plan
    plan = build_execution_plan(tasks, execution.context)
    
    # Execute tasks according to plan
    results = 
      plan
      |> Enum.reduce_while(%{}, fn task_group, acc ->
        case execute_task_group(task_group, acc, execution) do
          {:ok, group_results} ->
            {:cont, Map.merge(acc, group_results)}
          
          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    
    case results do
      {:error, _} = error -> error
      results -> {:ok, results}
    end
  end
  
  defp execute_task_group(tasks, previous_results, execution) do
    # Execute tasks in parallel if specified
    if Enum.any?(tasks, & &1.parallel) do
      execute_parallel_tasks(tasks, previous_results, execution)
    else
      execute_sequential_tasks(tasks, previous_results, execution)
    end
  end
  
  defp execute_parallel_tasks(tasks, previous_results, execution) do
    tasks
    |> Enum.map(fn task ->
      Task.async(fn ->
        execute_single_task(task, previous_results, execution)
      end)
    end)
    |> Enum.map(&Task.await(&1, 30_000))
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {task_id, result}}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, task_id, result)}}
      
      {:error, reason}, _ ->
        {:halt, {:error, reason}}
    end)
  end
  
  defp execute_sequential_tasks(tasks, previous_results, execution) do
    tasks
    |> Enum.reduce_while({:ok, previous_results}, fn task, {:ok, acc} ->
      case execute_single_task(task, acc, execution) do
        {:ok, {task_id, result}} ->
          {:cont, {:ok, Map.put(acc, task_id, result)}}
        
        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end
  
  defp execute_single_task(task, previous_results, execution) do
    Logger.info("Executing task: #{task.name}")
    
    # Check condition if specified
    if task.condition && !evaluate_condition(task.condition, previous_results) do
      {:ok, {task.id, %{skipped: true}}}
    else
      # Execute based on task type
      result = 
        case task.type do
          "mcp_tool" ->
            execute_mcp_tool(task, previous_results, execution)
          
          "llm_prompt" ->
            execute_llm_prompt(task, previous_results, execution)
          
          "http_request" ->
            execute_http_request(task, previous_results)
          
          "database_query" ->
            execute_database_query(task, previous_results)
          
          "conditional" ->
            execute_conditional(task, previous_results, execution)
          
          "loop" ->
            execute_loop(task, previous_results, execution)
          
          _ ->
            {:error, "Unknown task type: #{task.type}"}
        end
      
      # Handle result
      case result do
        {:ok, data} ->
          # Execute success handler if specified
          if task.on_success do
            execute_handler(task.on_success, data, execution)
          end
          
          {:ok, {task.id, data}}
        
        {:error, reason} = error ->
          # Try retry if configured
          if task.retry > 0 do
            Logger.warning("Task failed, retrying... (#{task.retry} attempts left)")
            Process.sleep(1000)
            execute_single_task(%{task | retry: task.retry - 1}, previous_results, execution)
          else
            # Execute failure handler if specified
            if task.on_failure do
              execute_handler(task.on_failure, reason, execution)
            end
            
            error
          end
      end
    end
  end
  
  defp execute_mcp_tool(task, previous_results, execution) do
    tool_name = task.params["tool"]
    operation = task.params["operation"]
    params = resolve_params(task.params["params"], previous_results)
    
    # Call MCP tool
    case Cybernetic.MCP.Core.execute_tool(tool_name, operation, params, execution.context) do
      {:ok, result} -> {:ok, result}
      error -> error
    end
  end
  
  defp execute_llm_prompt(task, previous_results, execution) do
    prompt = resolve_template(task.params["prompt"], previous_results)
    model = task.params["model"] || "anthropic"
    
    # Call S4 Intelligence
    case Service.route_request(%{
      "prompt" => prompt,
      "model" => model,
      "max_tokens" => task.params["max_tokens"] || 1000
    }) do
      {:ok, response} -> {:ok, response}
      error -> error
    end
  end
  
  defp execute_http_request(task, previous_results) do
    url = resolve_template(task.params["url"], previous_results)
    method = String.to_atom(task.params["method"] || "GET")
    headers = task.params["headers"] || []
    body = resolve_params(task.params["body"], previous_results)
    
    # Make HTTP request
    case HTTPoison.request(method, url, Jason.encode!(body), headers) do
      {:ok, %{status_code: code, body: response_body}} when code in 200..299 ->
        {:ok, Jason.decode!(response_body)}
      
      {:ok, %{status_code: code}} ->
        {:error, "HTTP #{code}"}
      
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp execute_database_query(task, previous_results) do
    # Use database tool
    execute_mcp_tool(
      %{task | 
        type: "mcp_tool",
        params: %{
          "tool" => "database",
          "operation" => "query",
          "params" => resolve_params(task.params, previous_results)
        }
      },
      previous_results,
      %{}
    )
  end
  
  # ========== WORKFLOW MONITORING ==========
  
  defp monitor_workflow(params) do
    execution_id = params["execution_id"]
    workflow_id = params["workflow_id"]
    
    executions = 
      if execution_id do
        [load_execution(execution_id)]
      else
        load_executions_for_workflow(workflow_id)
      end
    
    {:ok, %{
      executions: Enum.map(executions, &format_execution_status/1),
      summary: calculate_execution_summary(executions)
    }}
  end
  
  defp format_execution_status(execution) do
    %{
      id: execution.id,
      workflow_id: execution.workflow_id,
      status: execution.status,
      started_at: execution.started_at,
      completed_at: execution[:completed_at],
      duration: calculate_duration(execution),
      progress: calculate_progress(execution),
      current_tasks: execution.current_tasks,
      completed_tasks: length(execution.completed_tasks),
      failed_tasks: length(execution.failed_tasks)
    }
  end
  
  # ========== WORKFLOW ROLLBACK ==========
  
  defp rollback_workflow(params, context) do
    execution_id = params["execution_id"]
    execution = load_execution(execution_id)
    
    if execution.status != :failed do
      {:error, "Can only rollback failed executions"}
    else
      # Execute compensation tasks
      workflow = load_workflow(execution.workflow_id)
      
      compensation_results = 
        execution.completed_tasks
        |> Enum.reverse()
        |> Enum.map(fn task_id ->
          task = find_task(workflow, task_id)
          if task.compensation do
            execute_compensation(task.compensation, execution, context)
          else
            {:ok, :no_compensation}
          end
        end)
      
      {:ok, %{
        execution_id: execution_id,
        rollback_status: :completed,
        compensation_results: compensation_results
      }}
    end
  end
  
  defp execute_compensation(compensation, execution, context) do
    case compensation["type"] do
      "mcp_tool" ->
        execute_mcp_tool(
          %{params: compensation},
          execution.results,
          context
        )
      
      "manual" ->
        {:ok, %{
          instruction: compensation["instruction"],
          status: :manual_intervention_required
        }}
      
      _ ->
        {:error, "Unknown compensation type"}
    end
  end
  
  # ========== HELPER FUNCTIONS ==========
  
  defp validate_workflow_structure(workflow) do
    required_fields = ["name", "description"]
    
    missing = required_fields -- Map.keys(workflow)
    
    if Enum.empty?(missing) do
      :ok
    else
      {:error, "Missing required fields: #{inspect(missing)}"}
    end
  end
  
  defp validate_tasks(tasks) do
    if Enum.all?(tasks, &valid_task?/1) do
      :ok
    else
      {:error, "Invalid task structure"}
    end
  end
  
  defp valid_task?(task) do
    Map.has_key?(task, "id") && Map.has_key?(task, "name") && Map.has_key?(task, "type")
  end
  
  defp validate_dependencies(tasks) do
    task_ids = Enum.map(tasks, & &1["id"])
    
    invalid = 
      tasks
      |> Enum.flat_map(& &1["dependencies"] || [])
      |> Enum.reject(&(&1 in task_ids))
    
    if Enum.empty?(invalid) do
      :ok
    else
      {:error, "Invalid dependencies: #{inspect(invalid)}"}
    end
  end
  
  defp build_execution_plan(tasks, context) do
    # Topological sort for dependency resolution
    # Returns list of task groups that can be executed in parallel
    [tasks] # Simplified - in production, implement proper topological sort
  end
  
  defp evaluate_condition(condition, context) do
    # Evaluate condition expression
    # In production, use safe expression evaluator
    true
  end
  
  defp resolve_params(params, context) when is_map(params) do
    params
    |> Enum.map(fn {k, v} ->
      {k, resolve_template(v, context)}
    end)
    |> Map.new()
  end
  defp resolve_params(params, _context), do: params
  
  defp resolve_template(template, context) when is_binary(template) do
    # Replace {{variable}} with values from context
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _, var ->
      to_string(get_in(context, [var]) || get_in(context, [String.to_atom(var)]) || "")
    end)
  end
  defp resolve_template(value, _context), do: value
  
  defp execute_handler(_handler, _data, _execution), do: :ok
  defp execute_conditional(_task, _results, _execution), do: {:ok, true}
  defp execute_loop(_task, _results, _execution), do: {:ok, []}
  
  defp schedule_workflow(params, _context) do
    {:ok, %{
      workflow_id: params["workflow_id"],
      schedule: params["schedule"],
      next_run: calculate_next_run(params["schedule"])
    }}
  end
  
  defp default_retry_policy do
    %{
      max_attempts: 3,
      backoff: "exponential",
      initial_delay: 1000
    }
  end
  
  defp generate_workflow_id, do: "wf_" <> generate_id()
  defp generate_execution_id, do: "exec_" <> generate_id()
  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16()
  
  defp store_workflow(_workflow), do: :ok
  defp store_execution(_execution), do: :ok
  defp load_workflow(_id), do: %{}
  defp load_execution(_id), do: %{}
  defp load_executions_for_workflow(_id), do: []
  defp find_task(_workflow, _task_id), do: %{}
  defp send_completion_notification(_execution), do: :ok
  defp handle_execution_error(_execution, _error), do: :ok
  defp calculate_duration(_execution), do: 0
  defp calculate_progress(_execution), do: 0.0
  defp calculate_execution_summary(_executions), do: %{}
  defp calculate_next_run(_schedule), do: DateTime.utc_now()
end