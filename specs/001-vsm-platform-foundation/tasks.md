# Executable Tasks: VSM Platform Foundation

**Feature ID**: 001-vsm-platform-foundation
**Generated**: 2025-12-17
**Beads Epic**: TBD (will be created)

---

## Progress

- Started: 2025-12-17
- Last session: 2025-12-17
- Current phase: Task Generation
- Velocity: TBD

---

## Phase 1: Setup & Configuration

### T001: Create Ecto Repo Module
- [ ] [T001] [P] Create `lib/cybernetic/repo.ex` with Ecto.Repo
- **File**: `lib/cybernetic/repo.ex`
- **DoD**: Repo module compiles, config references it
- **Verify**: `mix compile` succeeds

### T002: Add Database Configuration
- [ ] [T002] Create database config in `config/config.exs` and `config/runtime.exs`
- **File**: `config/config.exs`, `config/runtime.exs`
- **DoD**: DATABASE_URL parsed, pool configured, query timeout set (30s default)
- **Verify**: `mix ecto.create` works with DATABASE_URL
- **Blocks**: T010-T016 (migrations need DB config)

### T003: Add Oban Configuration
- [ ] [T003] Add Oban to deps and configure queues
- **File**: `mix.exs`, `config/config.exs`
- **DoD**: Oban starts with configured queues
- **Verify**: `Oban.config()` returns expected queues

---

## Phase 2: Database Migrations (P0 - MVP)

### T010: Create Tenants Migration
- [ ] [T010] [P] [US1] Create `priv/repo/migrations/*_create_tenants.exs`
- **File**: `priv/repo/migrations/20251217000001_create_tenants.exs`
- **DoD**: Tenants table with id, name, slug, settings, timestamps
- **Verify**: `mix ecto.migrate` creates table

### T011: Create System States Migration
- [ ] [T011] [P] [US1] Create migration for VSM system states
- **File**: `priv/repo/migrations/20251217000002_create_system_states.exs`
- **DoD**: system_states table with tenant_id FK, system (1-5), state jsonb
- **Verify**: Migration runs, FK constraint works

### T012: Create Episodes Migration
- [ ] [T012] [P] [US1] Create migration for S4 episodes
- **File**: `priv/repo/migrations/20251217000003_create_episodes.exs`
- **DoD**: episodes table with tenant_id FK, title, content, analysis jsonb
- **Verify**: Migration runs, indexes created

### T013: Create Policies Migration
- [ ] [T013] [P] [US1] Create migration for S5 policies
- **File**: `priv/repo/migrations/20251217000004_create_policies.exs`
- **DoD**: policies table with tenant_id FK, name, rules jsonb, active boolean
- **Verify**: Migration runs

### T014: Create Artifacts Migration
- [ ] [T014] [P] [US1] Create migration for storage artifacts
- **File**: `priv/repo/migrations/20251217000005_create_artifacts.exs`
- **DoD**: artifacts table with tenant_id, path, content_type, size, metadata
- **Verify**: Migration runs

### T015: Create Oban Tables Migration
- [ ] [T015] [US1] Run Oban migration generator
- **Command**: `mix ecto.gen.migration add_oban_tables`
- **DoD**: Oban tables created
- **Verify**: `Oban.start_link/1` succeeds

### T016: Enable Row-Level Security
- [ ] [T016] [US1] Create RLS policies migration
- **File**: `priv/repo/migrations/20251217000007_enable_row_level_security.exs`
- **DoD**: RLS enabled on tenant-scoped tables with policies
- **Verify**: Cross-tenant queries blocked

---

## Phase 3: Ecto Schemas (P0 - MVP)

### T020: Create Tenant Schema
- [ ] [T020] [P] [US1] Create `lib/cybernetic/schemas/storage/tenant.ex`
- **File**: `lib/cybernetic/schemas/storage/tenant.ex`
- **DoD**: Schema with changeset, validation
- **Verify**: Unit tests pass

### T021: Create SystemState Schema
- [ ] [T021] [P] [US1] Create `lib/cybernetic/schemas/vsm/system_state.ex`
- **File**: `lib/cybernetic/schemas/vsm/system_state.ex`
- **DoD**: Schema with tenant belongs_to, system enum
- **Verify**: Unit tests pass

### T022: Create Episode Schema
- [ ] [T022] [P] [US1] Create `lib/cybernetic/schemas/vsm/episode.ex`
- **File**: `lib/cybernetic/schemas/vsm/episode.ex`
- **DoD**: Schema with tenant belongs_to, content/analysis
- **Verify**: Unit tests pass

### T023: Create Policy Schema
- [ ] [T023] [P] [US1] Create `lib/cybernetic/schemas/vsm/policy.ex`
- **File**: `lib/cybernetic/schemas/vsm/policy.ex`
- **DoD**: Schema with tenant belongs_to, rules jsonb
- **Verify**: Unit tests pass

### T024: Create Artifact Schema
- [ ] [T024] [P] [US1] Create `lib/cybernetic/schemas/storage/artifact.ex`
- **File**: `lib/cybernetic/schemas/storage/artifact.ex`
- **DoD**: Schema with tenant belongs_to, path, metadata
- **Verify**: Unit tests pass

---

## Phase 4: Docker Compose (P0 - MVP)

### T030: Create Base Docker Compose
- [ ] [T030] [US2] Create `docker/docker-compose.yml`
- **File**: `docker/docker-compose.yml`
- **DoD**: Services defined: app, db, redis, rabbitmq
- **Verify**: `docker compose config` validates

### T031: Create Dockerfile
- [ ] [T031] [US2] Create multi-stage `Dockerfile`
- **File**: `Dockerfile`
- **DoD**: Build and runtime stages, mix release
- **Verify**: `docker build .` succeeds

### T032: Create Entrypoint Script
- [ ] [T032] [US2] Create `docker/scripts/entrypoint.sh`
- **File**: `docker/scripts/entrypoint.sh`
- **DoD**: Runs migrations, starts app
- **Verify**: Script runs in container

### T033: Create Health Check Script
- [ ] [T033] [US2] Create `docker/scripts/healthcheck.sh`
- **File**: `docker/scripts/healthcheck.sh`
- **DoD**: Checks /health endpoint
- **Verify**: Health check passes

### T034: Create Environment Template
- [ ] [T034] [US2] Create `docker/.env.example`
- **File**: `docker/.env.example`
- **DoD**: All required env vars documented
- **Verify**: Compose starts with .env

### T035: Create Dev Compose Override
- [ ] [T035] [P] [US2] Create `docker/docker-compose.dev.yml`
- **File**: `docker/docker-compose.dev.yml`
- **DoD**: Mounts source, enables hot reload
- **Verify**: Code changes reflect immediately

### T036: Create Prod Compose Override
- [ ] [T036] [P] [US2] Create `docker/docker-compose.prod.yml`
- **File**: `docker/docker-compose.prod.yml`
- **DoD**: Optimized settings, resource limits
- **Verify**: Production config valid

---

## Phase 5: Edge Gateway Controllers (P1)

### T040: Implement SSE Events Controller
- [ ] [T040] [US3] Implement `lib/cybernetic/edge/gateway/controllers/events_controller.ex`
- **File**: `lib/cybernetic/edge/gateway/controllers/events_controller.ex`
- **DoD**: SSE streaming, topic subscription, heartbeat
- **Verify**: curl receives events

### T041: Add SSE Route
- [ ] [T041] [US3] Add GET /v1/events route to router
- **File**: `lib/cybernetic/edge/gateway/router.ex`
- **DoD**: Route exists, controller called
- **Verify**: Request reaches controller

### T042: Implement Telegram Controller
- [ ] [T042] [US4] Implement `lib/cybernetic/edge/gateway/controllers/telegram_controller.ex`
- **File**: `lib/cybernetic/edge/gateway/controllers/telegram_controller.ex`
- **DoD**: Webhook receives, validates signature, dispatches, rate limiting per chat_id
- **Verify**: Test webhook payload accepted, rate limit triggers on burst
- **Depends**: T020-T024 (schemas)

### T043: Add Telegram Route
- [ ] [T043] [US4] Add POST /telegram/webhook route
- **File**: `lib/cybernetic/edge/gateway/router.ex`
- **DoD**: Route exists, signature validated
- **Verify**: Webhook receives test message

### T044: Implement Metrics Controller
- [ ] [T044] [US5] Implement full metrics in `lib/cybernetic/edge/gateway/controllers/metrics_controller.ex`
- **File**: `lib/cybernetic/edge/gateway/controllers/metrics_controller.ex`
- **DoD**: Prometheus format, counters/gauges/histograms
- **Verify**: Prometheus can scrape

### T045: Add PromEx Configuration
- [ ] [T045] [US5] Configure PromEx for Phoenix/Ecto/Oban metrics
- **File**: `lib/cybernetic/prom_ex.ex`, `config/config.exs`
- **DoD**: Telemetry events captured
- **Verify**: /metrics shows all metrics

---

## Phase 6: Storage Abstraction (P2)

### T050: Create Storage Adapter Behaviour
- [ ] [T050] [P] [US6] Create `lib/cybernetic/storage/adapter.ex`
- **File**: `lib/cybernetic/storage/adapter.ex`
- **DoD**: Behaviour with store/retrieve/delete/exists?/list callbacks
- **Verify**: Behaviour compiles

### T051: Implement Local Adapter
- [ ] [T051] [US6] Create `lib/cybernetic/storage/adapters/local.ex`
- **File**: `lib/cybernetic/storage/adapters/local.ex`
- **DoD**: File operations, path safety, streaming for files >1MB
- **Verify**: Unit tests pass, 10MB file streams without OOM

### T052: Implement S3 Adapter
- [ ] [T052] [US6] Create `lib/cybernetic/storage/adapters/s3.ex`
- **File**: `lib/cybernetic/storage/adapters/s3.ex`
- **DoD**: ExAws S3 operations, multipart upload for files >5MB, streaming download
- **Verify**: Integration test with MinIO, 50MB file uploads successfully

### T053: Implement Memory Adapter
- [ ] [T053] [P] [US6] Create `lib/cybernetic/storage/adapters/memory.ex`
- **File**: `lib/cybernetic/storage/adapters/memory.ex`
- **DoD**: ETS-based, for testing
- **Verify**: Unit tests pass

### T054: Create Storage Module
- [ ] [T054] [US6] Create `lib/cybernetic/storage/storage.ex`
- **File**: `lib/cybernetic/storage/storage.ex`
- **DoD**: Routes to configured adapter
- **Verify**: Integration tests pass

---

## Phase 7: Background Processing (P2)

### T060: Create Base Worker
- [ ] [T060] [P] [US7] Create `lib/cybernetic/workers/base_worker.ex`
- **File**: `lib/cybernetic/workers/base_worker.ex`
- **DoD**: Shared behaviour, error handling
- **Verify**: Compiles

### T061: Create Episode Analyzer Worker
- [ ] [T061] [US7] Create `lib/cybernetic/workers/episode_analyzer.ex`
- **File**: `lib/cybernetic/workers/episode_analyzer.ex`
- **DoD**: Oban worker, analyzes episodes
- **Verify**: Enqueue and execute works

### T062: Create Policy Evaluator Worker
- [ ] [T062] [US7] Create `lib/cybernetic/workers/policy_evaluator.ex`
- **File**: `lib/cybernetic/workers/policy_evaluator.ex`
- **DoD**: Oban worker, evaluates policies
- **Verify**: Enqueue and execute works

### T063: Create Notification Sender Worker
- [ ] [T063] [US7] Create `lib/cybernetic/workers/notification_sender.ex`
- **File**: `lib/cybernetic/workers/notification_sender.ex`
- **DoD**: Oban worker, sends notifications
- **Verify**: Enqueue and execute works

---

## Phase 8: Testing

### T070: Create Test Factories
- [ ] [T070] [P] Create `test/support/factory.ex`
- **File**: `test/support/factory.ex`
- **DoD**: Factories for all schemas
- **Verify**: Factories generate valid data

### T071: Schema Unit Tests
- [ ] [T071] [P] Create tests for all schemas
- **File**: `test/cybernetic/schemas/**/*_test.exs`
- **DoD**: Changeset validation tested
- **Verify**: Tests pass

### T072: Storage Adapter Tests
- [ ] [T072] [P] Create tests for storage adapters
- **File**: `test/cybernetic/storage/adapters/*_test.exs`
- **DoD**: All adapter operations tested
- **Verify**: Tests pass

### T073: Controller Tests
- [ ] [T073] Create controller integration tests
- **File**: `test/cybernetic_edge/gateway/controllers/*_test.exs`
- **DoD**: All endpoints tested
- **Verify**: Tests pass

### T074: Worker Tests
- [ ] [T074] Create Oban worker tests
- **File**: `test/cybernetic/workers/*_test.exs`
- **DoD**: Enqueue/execute tested
- **Verify**: Tests pass

### T075: Docker Compose E2E Test
- [ ] [T075] Test full Docker Compose stack
- **Command**: `docker compose up -d && ./test_endpoints.sh`
- **DoD**: All services healthy, endpoints respond
- **Verify**: E2E script passes

---

## Phase 9: Documentation

### T080: Update README
- [ ] [T080] [P] Update `README.md` with setup instructions
- **File**: `README.md`
- **DoD**: Docker setup documented
- **Verify**: New dev can follow

### T081: Create Runbook
- [ ] [T081] [P] Create `docs/RUNBOOK.md`
- **File**: `docs/RUNBOOK.md`
- **DoD**: Common operations documented
- **Verify**: Ops can follow

---

## Task Summary

| Phase | Tasks | Parallel | Status |
|-------|-------|----------|--------|
| Setup | T001-T003 | 2 | Pending |
| Migrations | T010-T016 | 5 | Pending |
| Schemas | T020-T024 | 5 | Pending |
| Docker | T030-T036 | 3 | Pending |
| Controllers | T040-T045 | 0 | Pending |
| Storage | T050-T054 | 3 | Pending |
| Workers | T060-T063 | 1 | Pending |
| Testing | T070-T075 | 3 | Pending |
| Docs | T080-T081 | 2 | Pending |

**Total**: 40 tasks
**Parallelizable**: 24 tasks
**Sequential**: 16 tasks
