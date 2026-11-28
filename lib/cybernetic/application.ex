defmodule Cybernetic.Application do
  @moduledoc """
  Boots the Cybernetic runtime mapped to VSM systems.

  In test mode (`:minimal_test_mode`), only essential services are started:
  - JWKSCache, AuthManager (for auth/JWT tests)
  - Phoenix.PubSub (for event tests)

  This dramatically improves test speed and reduces noise.
  """
  use Application
  require Logger

  @impl Application
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    # Validate critical configuration before starting
    with :ok <- validate_configuration() do
      env = Application.get_env(:cybernetic, :environment, :prod)
      minimal_test? = Application.get_env(:cybernetic, :minimal_test_mode, false)

      # Initialize OpenTelemetry with error handling
      if env != :test do
        try do
          Cybernetic.Telemetry.OTEL.setup()
          Logger.info("OpenTelemetry initialized for service: cybernetic")
        rescue
          e ->
            Logger.warning("OpenTelemetry initialization failed: #{inspect(e)}")
            # Continue without OpenTelemetry for now
            :ok
        end
      end

      amqp_enabled? =
        Application.get_env(:cybernetic, :amqp, [])
        |> Keyword.get(:enabled, true)

      repo_children =
        if env == :test do
          []
        else
          [
            # Database - must start first
            Cybernetic.Repo,
            # Background job processor
            {Oban, Application.fetch_env!(:cybernetic, Oban)},
            # PromEx metrics
            Cybernetic.PromEx
          ]
        end

      cluster_children =
        if env == :test do
          []
        else
          [
            # Cluster discovery
            {Cluster.Supervisor,
             [
               Application.get_env(:libcluster, :topologies, []),
               [name: Cybernetic.ClusterSupervisor]
             ]}
          ]
        end

      # S4 AMQP Consumer - only when AMQP is enabled. It was previously
      # started unconditionally; with AMQP disabled its first
      # GenServer.call to the (absent) AMQP Connection process exits,
      # crash-looping until the root supervisor exhausts its restarts
      # and the whole application shuts down.
      s4_amqp_consumer_children =
        if amqp_enabled? do
          [{Cybernetic.VSM.System4.AMQPConsumer, []}]
        else
          []
        end

      # VSM AMQP Consumers for the remaining canonical queues
      # (coupling #6, stage 2) - the same AMQP-enabled gate as the
      # S4 consumer above, for the same reason: with AMQP disabled
      # a consumer's first channel request to the absent Connection
      # process would crash-loop it. Each instance of the shared
      # consumer module owns one queue and dispatches deliveries to
      # that system's message handler; System3 deliveries go to
      # ControlSupervisor.process_vsm_message/2.
      vsm_amqp_consumer_children =
        if amqp_enabled? do
          [
            {Cybernetic.VSM.AMQPConsumer,
             queue: "cyb.s1.ops", system: :system1, name: Cybernetic.VSM.AMQPConsumer.S1},
            {Cybernetic.VSM.AMQPConsumer,
             queue: "cyb.s2.coord", system: :system2, name: Cybernetic.VSM.AMQPConsumer.S2},
            {Cybernetic.VSM.AMQPConsumer,
             queue: "cyb.s3.control", system: :system3, name: Cybernetic.VSM.AMQPConsumer.S3},
            {Cybernetic.VSM.AMQPConsumer,
             queue: "cyb.s5.policy", system: :system5, name: Cybernetic.VSM.AMQPConsumer.S5}
          ]
        else
          []
        end

      # Craft Anything MCP bridge - only when explicitly enabled via
      # config :cybernetic, :craft_mcp, enabled: true. It spawns the
      # external `craft-anything-cli mcp` process and registers its
      # tools in the Hermes registry, so it stays off by default.
      craft_mcp_children =
        if Application.get_env(:cybernetic, :craft_mcp, []) |> Keyword.get(:enabled, false) do
          [Cybernetic.Core.MCP.CraftBridge]
        else
          []
        end

      # Magg MCP aggregator bridge - only when explicitly enabled
      # via config :cybernetic, :magg, enabled: true. It spawns the
      # external `magg serve` sidecar process and registers its
      # tools in the Hermes registry, so it stays off by default.
      magg_children =
        if Application.get_env(:cybernetic, :magg, []) |> Keyword.get(:enabled, false) do
          [Cybernetic.MCP.MAGGAdapter]
        else
          []
        end

      amqp_children =
        if amqp_enabled? do
          [
            # AMQP Transport
            Cybernetic.Transport.AMQP.Connection,
            {Cybernetic.Core.Transport.AMQP.Topology, []},
            # Lamport clock (Phase 1, IP-31): ticks at the publish
            # choke point, merges and detects regressions at the
            # consume choke points
            Cybernetic.Transport.AMQP.LamportClock,
            Cybernetic.Core.Transport.AMQP.Publisher,
            # Performance Optimizations
            {Cybernetic.Core.Transport.AMQP.PublisherPool, []}
          ]
        else
          []
        end

      children =
        if minimal_test? do
          # Minimal children for fast unit tests - only essential services
          minimal_test_children()
        else
          # Full children for production/integration tests
          (repo_children ++
             [
               # Phoenix PubSub (used by SSE and event broadcasting)
               {Phoenix.PubSub, name: Cybernetic.PubSub},
               # SSE Supervisor (owns connection tracking ETS table)
               Cybernetic.Edge.Gateway.SSESupervisor,
               # Cluster discovery
               cluster_children,
               # Phoenix Edge Gateway Endpoint
               Cybernetic.Edge.Gateway.Endpoint,
               # oh-my-opencode MCP server (mounted at /mcp)
               {Cybernetic.Integrations.OhMyOpencode.MCPProvider, transport: :streamable_http},
               # Core Security
               Cybernetic.Core.Security.NonceBloom,
               # CRDT Graph
               Cybernetic.Core.CRDT.Graph,
               # CRDT Context Graph for semantic triples
               Cybernetic.Core.CRDT.ContextGraph,
               # AMQP Transport
               amqp_children,
               {Cybernetic.Core.CRDT.Cache, []},
               {Cybernetic.Telemetry.BatchedCollector, []},
               # MCP Registry
               Cybernetic.Core.MCP.Hermes.Registry,
               craft_mcp_children,
               magg_children,
               # Circuit Breaker Registry
               {Registry,
                keys: :unique, name: Cybernetic.Core.Resilience.AdaptiveCircuitBreaker.Registry},
               # Edge Gateway Circuit Breaker
               {Cybernetic.Core.Resilience.AdaptiveCircuitBreaker, name: :edge_gateway},
               # Goldrush Integration
               {Cybernetic.Core.Goldrush.Plugins.TelemetryAlgedonic, []},
               Cybernetic.Core.Goldrush.Bridge,
               Cybernetic.Core.Goldrush.Pipeline,
               # Central Aggregator (must be before S4 Bridge)
               {Cybernetic.Core.Aggregator.CentralAggregator, []},
               # S5 SOP Engine (must be before S4 Bridge so it can receive messages)
               {Cybernetic.VSM.System5.SOPEngine, []},
               # S5 Policy Intelligence Engine
               {Cybernetic.VSM.System5.PolicyIntelligence, []},
               # S4 Intelligence Layer
               Cybernetic.VSM.System4.LLMBridge,
               # S4 Multi-Provider Intelligence Service
               {Cybernetic.VSM.System4.Service, []},
               # S4 AMQP Consumer for processing intelligence requests
               # (spliced only when AMQP is enabled - see above)
               s4_amqp_consumer_children,
               # VSM AMQP Consumers for the s1/s2/s3/s5 canonical
               # queues (spliced only when AMQP is enabled - see above)
               vsm_amqp_consumer_children,
               # S4 Memory for conversation context
               {Cybernetic.VSM.System4.Memory, []},
               # S3 Rate Limiter for budget management
               {Cybernetic.VSM.System3.RateLimiter, []},
               # JWKS Cache for JWT/OIDC verification (must start before AuthManager)
               {Cybernetic.Security.JWKSCache, []},
               # Security AuthManager for MCP tools
               {Cybernetic.Security.AuthManager, []},
               # Edge WASM Validator is stateless - use Cybernetic.Edge.WASM.Validator.load/2 where needed
               # VSM Supervisor (includes S1-S5)
               Cybernetic.VSM.Supervisor,
               # HNSW vector index - the shared similarity-search DP
               # (Axiomatic Design coupling #5). It existed and was
               # fully implemented but never started: its only
               # supervisor was referenced nowhere. Dimensions come
               # from the embeddings config so the index matches the
               # configured provider's vectors.
               {Cybernetic.Intelligence.HNSW.Index,
                [
                  name: Cybernetic.Intelligence.HNSW.Index,
                  dimensions:
                    Application.get_env(:cybernetic, :embeddings, [])
                    |> Keyword.get(:dimensions, 768),
                  m: 16,
                  ef_construction: 200
                ]},
               # Content subsystem (semantic containers, CBCP buckets,
               # ingest pipeline) - implemented but never started before
               # the 2026-11-23 audit (Issue #86, P0)
               Cybernetic.Content.Supervisor,
               # Capabilities subsystem (registry, planner collaboration,
               # execution handoff, MCP router, LLM CDN) - likewise
               # implemented but never started
               Cybernetic.Capabilities.Supervisor,
               # S3 ControlSupervisor (audit/health/compliance monitoring).
               # Distinct from VSM.System3.Control inside VSM.Supervisor;
               # Cybernetic.Core.Resilience.AdaptiveCircuitBreaker already
               # looks this process up by name
               Cybernetic.VSM.System3.ControlSupervisor
             ])
          |> List.flatten()
          |> Kernel.++(health_children())
          |> Kernel.++(telemetry_children())
          |> Kernel.++(audit_children())
        end

      opts = [
        strategy: :one_for_one,
        name: Cybernetic.Supervisor,
        max_restarts: 10,
        max_seconds: 60
      ]

      {:ok, sup} = Supervisor.start_link(children, opts)

      # Block on MCP tools so S1-S5 workers can assume availability
      Task.start(fn ->
        case Cybernetic.Core.MCP.Hermes.Registry.await_ready(2_000) do
          :ok ->
            Logger.info("MCP Registry ready with builtin tools")

          {:error, :timeout} ->
            Logger.error("MCP registry not ready in time")
        end
      end)

      {:ok, sup}
    else
      {:error, reason} ->
        Logger.error("Configuration validation failed: #{reason}")
        {:error, reason}
    end
  end

  # Configuration validation
  defp validate_configuration do
    env = Application.get_env(:cybernetic, :environment, :prod)

    case env do
      env when env in [:test, :dev] ->
        # In dev/test, just warn about missing production variables
        if System.get_env("JWT_SECRET") == "dev-secret-change-in-production" do
          Logger.info("Using default JWT_SECRET for #{env} environment")
        end

        :ok

      :prod ->
        # In production, require proper configuration
        required_env_vars = [
          "JWT_SECRET",
          "PASSWORD_SALT",
          "SECRET_KEY_BASE",
          "CYBERNETIC_HMAC_SECRET"
        ]

        missing =
          Enum.filter(required_env_vars, fn var ->
            case {var, System.get_env(var)} do
              {_var, nil} ->
                true

              {_var, ""} ->
                true

              # Default not allowed in prod
              {"JWT_SECRET", "dev-secret-change-in-production"} ->
                true

              {"PASSWORD_SALT", "cybernetic_default_salt_change_in_prod"} ->
                true

              {_var, _} ->
                false
            end
          end)

        if missing != [] do
          {:error,
           "Missing/invalid required environment variables in production: #{Enum.join(missing, ", ")}"}
        else
          # Validate JWT secret strength in production
          jwt_secret = System.get_env("JWT_SECRET")

          if String.length(jwt_secret) < 32 do
            {:error, "JWT_SECRET must be at least 32 characters in production"}
          else
            # Validate Phoenix secret_key_base strength in production
            secret_key_base = System.get_env("SECRET_KEY_BASE")

            if byte_size(secret_key_base) < 64 do
              {:error, "SECRET_KEY_BASE must be at least 64 characters in production"}
            else
              password_salt = System.get_env("PASSWORD_SALT")

              if byte_size(password_salt) < 16 do
                {:error, "PASSWORD_SALT must be at least 16 characters in production"}
              else
                :ok
              end
            end
          end
        end
    end
  end

  # Add health monitoring children conditionally
  defp health_children do
    if Application.get_env(:cybernetic, :enable_health_monitoring, true) do
      [
        Cybernetic.Health.Supervisor,
        Cybernetic.Core.Resilience.CircuitBreakerAlerts
      ]
    else
      []
    end
  end

  # The audit log (Phase 1, IP-27): the system's record-keeper. It
  # sits outside the VSM supervision subtree - no VSM system
  # supervises, restarts, or configures it - and starts only in the
  # full tree (never in minimal test mode).
  defp audit_children do
    [Cybernetic.Audit.Log]
  end

  # Add telemetry children conditionally
  defp telemetry_children do
    if Application.get_env(:cybernetic, :enable_telemetry, true) do
      [Cybernetic.Telemetry.Supervisor]
    else
      []
    end
  end

  # Minimal children for fast unit tests
  # Only starts services actually needed by most unit tests
  defp minimal_test_children do
    Logger.info("Starting in minimal test mode - only essential services")

    [
      # Phoenix PubSub (for event tests)
      {Phoenix.PubSub, name: Cybernetic.PubSub},
      # Core Security (for nonce/replay tests)
      Cybernetic.Core.Security.NonceBloom,
      # JWKS Cache (for JWT tests)
      {Cybernetic.Security.JWKSCache, []},
      # AuthManager (for auth tests)
      {Cybernetic.Security.AuthManager, []},
      # MCP Registry (for capability tests)
      Cybernetic.Core.MCP.Hermes.Registry,
      # Integrations Registry (for streaming/integration tests)
      {Registry, keys: :unique, name: Cybernetic.Integrations.Registry},
      # Rate Limiter (for rate limit tests)
      {Cybernetic.VSM.System3.RateLimiter, []}
    ]
  end
end
