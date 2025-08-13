
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
      # Core dependencies
      {:amqp, "~> 4.1"},
      {:jason, ">= 0.0.0"},
      {:telemetry, ">= 0.0.0"},
      {:libcluster, ">= 0.0.0"},
      {:delta_crdt, ">= 0.0.0"},
      {:rustler, ">= 0.0.0"},
      
      # MCP integration
      {:hermes_mcp, git: "https://github.com/cloudwalk/hermes-mcp", branch: "main", optional: true},
      
      # Goldrush branches for reactive stream processing
      {:goldrush, git: "https://github.com/DeadZen/goldrush", branch: "master"},
      {:goldrush_elixir, git: "https://github.com/DeadZen/goldrush", branch: "develop-elixir", app: false},
      {:goldrush_telemetry, git: "https://github.com/DeadZen/goldrush", branch: "develop-telemetry", app: false},
      {:goldrush_plugins, git: "https://github.com/DeadZen/goldrush", branch: "develop-plugins", app: false}
      
      # Telegram bot integration
      {:ex_gram, "~> 0.52"},  # More modern Telegram bot library
      
      # Security and utilities
      {:bloomex, "~> 1.0"},  # Bloom filter for replay protection
      {:nanoid, "~> 2.0"},    # Nonce generation
      
      # Web UI (Phoenix)
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 0.20"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:plug_cowboy, "~> 2.5"}
    ]
  end
end
