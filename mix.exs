
defmodule Cybernetic.MixProject do
  use Mix.Project

  def project do
    [
      app: :cybernetic,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Cybernetic.Application, []}
    ]
  end

  defp deps do
    [
      {:amqp, "~> 4.1"},
      {:jason, ">= 0.0.0"},
      {:telemetry, ">= 0.0.0"},
      {:libcluster, ">= 0.0.0"},
      {:delta_crdt, ">= 0.0.0"},
      {:rustler, ">= 0.0.0"}
      # Goldrush and Hermes-MCP can be added as Git deps once you wire them:
      # {:goldrush, git: "https://github.com/DeadZen/goldrush", branch: "develop-elixir"},
      # {:hermes_mcp, git: "https://github.com/cloudwalk/hermes-mcp"}
    ]
  end
end
