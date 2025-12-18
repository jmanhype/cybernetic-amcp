import Config

# Database Configuration
# Supports DATABASE_URL or individual components
database_url = System.get_env("DATABASE_URL")

if database_url do
  config :cybernetic, Cybernetic.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    queue_target: String.to_integer(System.get_env("ECTO_QUEUE_TARGET") || "50"),
    queue_interval: String.to_integer(System.get_env("ECTO_QUEUE_INTERVAL") || "1000"),
    timeout: String.to_integer(System.get_env("ECTO_TIMEOUT") || "30000"),
    ssl: System.get_env("DATABASE_SSL") == "true"
else
  config :cybernetic, Cybernetic.Repo,
    username: System.get_env("PGUSER") || "cybernetic",
    password: System.get_env("PGPASSWORD") || "cybernetic",
    hostname: System.get_env("PGHOST") || "localhost",
    database: System.get_env("PGDATABASE") || "cybernetic_#{config_env()}",
    port: String.to_integer(System.get_env("PGPORT") || "5432"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    timeout: String.to_integer(System.get_env("ECTO_TIMEOUT") || "30000")
end

# Oban production configuration
if config_env() == :prod do
  config :cybernetic, Oban,
    plugins: [
      {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},  # 7 days
      {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
      {Oban.Plugins.Cron, crontab: [
        {"0 * * * *", Cybernetic.Workers.HealthCheck, queue: :default},
        {"*/5 * * * *", Cybernetic.Workers.MetricsCollector, queue: :default}
      ]}
    ],
    queues: [
      default: 20,
      critical: 50,
      analysis: 10,
      notifications: 10,
      storage: 5
    ]
end

# Transport Configuration for VSM message passing
# Use AMQP transport in production, can be overridden in test.exs
config :cybernetic, :transport, Cybernetic.Transport.AMQP

# AMQP Configuration for production transport
config :cybernetic, :amqp,
  url: System.get_env("AMQP_URL") || "amqp://cybernetic:changeme@localhost:5672",
  exchange: System.get_env("AMQP_EXCHANGE") || "cyb.commands",
  exchange_type: :topic,
  exchanges: %{
    events: "cyb.events",
    telemetry: "cyb.telemetry",
    commands: "cyb.commands",
    mcp_tools: "cyb.mcp.tools",
    s1: "cyb.vsm.s1",
    s2: "cyb.vsm.s2",
    s3: "cyb.vsm.s3",
    s4: "cyb.vsm.s4",
    s5: "cyb.vsm.s5"
  },
  queues: [
    system1: "vsm.system1.operations",
    system2: "vsm.system2.coordination",
    system3: "vsm.system3.control",
    system4: "vsm.system4.intelligence",
    system5: "vsm.system5.policy"
  ]

# VSM System Configuration
config :cybernetic, :vsm,
  enable_system1: true,
  enable_system2: true,
  enable_system3: true,
  enable_system4: true,
  enable_system5: true,
  telemetry_interval: 5_000

# MCP (Model Context Protocol) Configuration
config :cybernetic, :mcp,
  registry_timeout: 5_000,
  client_timeout: 30_000,
  max_retries: 3,
  enable_vsm_tools: true

# Goldrush Configuration for Event Processing
config :cybernetic, :goldrush,
  event_buffer_size: 1000,
  flush_interval: 100,
  enable_telemetry: true

# Security configuration
# P0 Security: HMAC secret must be consistent across nodes/restarts
hmac_secret =
  case {config_env(), System.get_env("CYBERNETIC_HMAC_SECRET")} do
    {:prod, nil} ->
      raise "CYBERNETIC_HMAC_SECRET is required in production"

    {:prod, ""} ->
      raise "CYBERNETIC_HMAC_SECRET cannot be empty in production"

    {_, secret} when is_binary(secret) ->
      secret

    {env, _} when env in [:dev, :test] ->
      # Only use random fallback in dev/test - NOT for production
      :crypto.strong_rand_bytes(32) |> Base.encode64()
  end

config :cybernetic, :security,
  hmac_secret: hmac_secret,
  # 5 minutes
  nonce_ttl: 300_000,
  bloom_size: 100_000,
  bloom_error_rate: 0.001

# P0 Security: Phoenix secret_key_base from environment
secret_key_base =
  case {config_env(), System.get_env("SECRET_KEY_BASE")} do
    {:prod, nil} ->
      raise "SECRET_KEY_BASE is required in production (min 64 chars)"

    {:prod, secret} when byte_size(secret) < 64 ->
      raise "SECRET_KEY_BASE must be at least 64 characters in production"

    {_, secret} when is_binary(secret) and byte_size(secret) >= 64 ->
      secret

    {env, _} when env in [:dev, :test] ->
      # Dev/test fallback - never use in production
      "dev-only-secret-key-base-that-is-at-least-64-characters-long-for-testing"
  end

config :cybernetic, Cybernetic.Edge.Gateway.Endpoint,
  secret_key_base: secret_key_base

# NonceBloom specific config
config :cybernetic, Cybernetic.Core.Security.NonceBloom,
  replay_window_sec: 90,
  bloom_bits_per_entry: 10,
  bloom_error_rate: 0.001,
  persist_path: System.get_env("CYB_BLOOM_FILE") || "/tmp/cyb.bloom"

# S4 Intelligence Multi-Provider Configuration
config :cybernetic, :s4,
  default_chain: [
    anthropic: [model: "claude-3-5-sonnet-20241022"],
    openai: [model: "gpt-4o"],
    together: [model: "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo"],
    ollama: [model: "llama3.2:3b"]
  ],
  timeout_ms: 30_000,
  health_check_interval: 60_000,
  circuit_breaker_threshold: 5

# LLM Stack Selection (req_llm_pipeline or legacy_httpoison)
llm_stack =
  case System.get_env("LLM_STACK", "legacy_httpoison") do
    "req_llm_pipeline" -> :req_llm_pipeline
    "legacy_httpoison" -> :legacy_httpoison
    other -> raise "Invalid LLM_STACK value: #{inspect(other)}"
  end

config :cybernetic, :llm_stack,
  stack: llm_stack

# Provider-specific configurations
config :cybernetic, Cybernetic.VSM.System4.Providers.Anthropic,
  api_key: {:system, "ANTHROPIC_API_KEY"},
  model: "claude-3-5-sonnet-20241022",
  max_tokens: 8192,
  temperature: 0.1

config :cybernetic, Cybernetic.VSM.System4.Providers.OpenAI,
  api_key: {:system, "OPENAI_API_KEY"},
  model: "gpt-4o",
  max_tokens: 4096,
  temperature: 0.1

config :cybernetic, Cybernetic.VSM.System4.Providers.Ollama,
  endpoint: System.get_env("OLLAMA_ENDPOINT") || "http://localhost:11434",
  model: "llama3.2:3b",
  max_tokens: 2048,
  temperature: 0.1

config :cybernetic, Cybernetic.VSM.System4.Providers.Together,
  api_key: {:system, "TOGETHER_API_KEY"},
  model: "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo",
  max_tokens: 4096,
  temperature: 0.1

# OpenTelemetry Configuration
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  resource: [
    service: %{
      name: "cybernetic",
      version: "0.1.0"
    }
  ]

config :opentelemetry_exporter,
  otlp_protocol: :grpc,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") || "http://localhost:4317",
  otlp_headers: System.get_env("OTEL_EXPORTER_OTLP_HEADERS") || "",
  otlp_compression: :gzip

# Prometheus metrics exporter
config :telemetry_metrics_prometheus_core,
  port: String.to_integer(System.get_env("METRICS_PORT") || "9568"),
  path: "/metrics",
  format: :text,
  registry: :default

# Application configuration
config :cybernetic,
  environment: config_env(),
  node_name: node()
