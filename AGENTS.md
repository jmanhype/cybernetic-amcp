# Repository Guidelines

## Project Structure & Modules
- `lib/`: Elixir application code (VSM systems, MCP, transport, telemetry). Entry modules under `Cybernetic.*`.
- `test/`: ExUnit tests and verification suites; integration/property checks live here.
- `scripts/`: Developer utilities and system proofs (e.g., `scripts/prove/*.exs`, `scripts/test/*.exs`).
- `config/`: Runtime and environment config; Docker Compose in `config/docker/`.
- `docs/`, `site/`: Documentation and generated site.
- `infrastructure/`: Deployment (Kubernetes, etc.).

## Build, Test, and Run
- Install deps: `make deps` (or `mix deps.get && mix deps.compile`).
- Run locally: `make dev` (starts `iex -S mix`).
- Unit tests: `make test` (alias for `MIX_ENV=test mix test`).
- Coverage: `make test-coverage` (opens `cover/excoveralls.html`).
- Lint/format: `make lint` and `make format`.
- Services: `docker-compose -f config/docker/docker-compose.yml up -d`.
- Release: `make release` or container via `make docker-build`.

## Coding Style & Naming
- Elixir style: 2-space indentation, `snake_case` functions, `PascalCase` modules (e.g., `Cybernetic.VSM.System4.Service`).
- Write `@moduledoc`/`@doc` for public modules/functions; prefer pure functions and pattern matching.
- Format with `mix format`; lint with `mix credo --strict` before pushing.
- Tests live in `test/**/*_test.exs`; auxiliary proofs can live under `scripts/test/*.exs`.

## Testing Guidelines
- Framework: ExUnit; run targeted tests: `mix test test/core/foo_test.exs:42`.
- Integration: `mix test --include integration` (see Makefile targets for helpers).
- Aim for meaningful coverage on core flows (transport, VSM S1–S5, MCP registry). Use `MIX_ENV=test`.

## Commits & Pull Requests
- Conventional commits encouraged: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `ci:`. Scopes welcome: `fix(core/amqp): reconnect on channel error`.
- PRs must include: clear description, linked issues, relevant logs/screenshots, test coverage for changes, and passing `make check`.
- Keep diffs focused; note any config changes (`config/*.exs`, `config/docker/*`).

## Security & Configuration
- Never commit secrets. Copy `.env.example` to `.env` for local use.
- Production requires strong envs (see `Cybernetic.Application`): `JWT_SECRET` (≥32 chars) and `PASSWORD_SALT`.
- Validate services with `make verify`; observability dashboards run via `make monitor`.

## Roadmap & Backlog
- Source: `blackbox_roadmap_with_backlog.json`.
- Generated views: `docs/ROADMAP.md`, `docs/ROADMAP_KANBAN.md`, CSV at `docs/roadmap.csv`.
- GitHub import: `tools/github/issues_import.csv` (labels `phase:*`, `status:*`).
- Regenerate: `python3 scripts/roadmap/generate.py`.
- Create issues via CLI: `python3 scripts/roadmap/create_github_issues.py --repo <owner/name>`.
