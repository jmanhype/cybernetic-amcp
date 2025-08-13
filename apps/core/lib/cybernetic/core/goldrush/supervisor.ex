defmodule Cybernetic.Core.Goldrush.Supervisor do
  @moduledoc """
  Supervises Goldrush telemetry + plugin runners (branches: telemetry/plugins/elixir).
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts) do
    children = [
      # Placeholders for goldrush processes once deps are added
      {Task.Supervisor, name: Cybernetic.Core.Goldrush.TaskSup}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
