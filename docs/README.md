
# Cybernetic (aMCP) – Scaffold

Single Mix app mirroring your requested `apps/*` layout under `lib/`, with OTP supervisors for VSM (S1–S5), AMQP transport, MCP (Hermes/MAGG stubs), CRDT context graph, Goldrush placeholders, Telegram S1 agent, and a UI placeholder.

Next steps:
1. Add Git deps for Goldrush (develop-* branches) and Hermes MCP in `mix.exs`.
2. Configure `:amqp_url` in runtime config.
3. Flesh out modules under `lib/core/mcp/*`, `lib/core/goldrush/*`, and `lib/apps/telegram/*`.
4. `mix deps.get && iex -S mix` (deps will need internet).
