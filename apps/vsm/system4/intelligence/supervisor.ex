
defmodule Cybernetic.System4.Intelligence.Supervisor do
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: Supervisor.init([Cybernetic.System4.LLMBridge], strategy: :one_for_one)
end

defmodule Cybernetic.System4.LLMBridge do
  @moduledoc """
  HTTP-based LLM bridge for S4 reasoning/policy synthesis.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_), do: {:ok, Finch.start_link(name: __MODULE__)}

  def ask(%{prompt: prompt} = params) do
    base = Application.get_env(:cybernetic, __MODULE__)[:http_base]
    body = Jason.encode!(%{model: "generic", prompt: prompt, params: Map.drop(params, [:prompt])})
    req = Finch.build(:post, base <> "/v1/complete", [{"content-type","application/json"}], body)
    with {:ok, %Finch.Response{status: 200, body: body}} <- Finch.request(req, __MODULE__),
         {:ok, %{"text" => text}} <- Jason.decode(body) do
      {:ok, text}
    else
      _ -> {:error, :llm_down}
    end
  end
end
