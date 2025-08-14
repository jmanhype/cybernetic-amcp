
defmodule Cybernetic.VSM.System5.Policy do
  use GenServer
  @moduledoc """
  S5: Identity/goal setting + meta-system spawning.
  """

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  
  def init(state) do
    {:ok, state
      |> Map.put(:identity, %{name: "Cybernetic"})
      |> Map.put(:policies, %{})
      |> Map.put(:policy_history, %{})}
  end
  
  @doc "Store a policy with versioning"
  def put_policy(id, policy), do: GenServer.call(__MODULE__, {:put_policy, id, policy})
  
  @doc "Get current policy version"
  def get_policy(id), do: GenServer.call(__MODULE__, {:get_policy, id})
  
  @doc "Get diff between two policy versions"
  def diff_policy(id, v1, v2), do: GenServer.call(__MODULE__, {:diff_policy, id, v1, v2})
  
  # Handle transport messages from in-memory transport
  def handle_cast({:transport_message, message, opts}, state) do
    # Route message to the appropriate message handler
    operation = Map.get(message, "operation", "unknown")
    meta = Keyword.get(opts, :meta, %{})
    
    # Process the message through the message handler
    Cybernetic.VSM.System5.MessageHandler.handle_message(operation, message, meta)
    
    {:noreply, state}
  end
  
  # Test interface - routes messages through the message handler
  def handle_message(message, meta \\ %{}) do
    operation = Map.get(message, :operation, "unknown")
    Cybernetic.VSM.System5.MessageHandler.handle_message(operation, message, meta)
  end
end
