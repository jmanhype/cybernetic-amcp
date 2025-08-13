
defmodule Cybernetic.System5.PolicySupervisor do
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: Supervisor.init([Cybernetic.System5.PolicyManager], strategy: :one_for_one)
end

defmodule Cybernetic.System5.PolicyManager do
  use GenServer
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_), do: {:ok, %{policies: %{}}}
end
