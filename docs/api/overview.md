# API Overview

Cybernetic’s Edge Gateway is a Phoenix HTTP API that fronts the VSM systems.

## Authentication

Production requests to `/v1/*` require one of:

- `x-api-key: <key>` (recommended): set `CYBERNETIC_SYSTEM_API_KEY` and send it as `x-api-key`
- `Authorization: Bearer <token>`: validated by `Cybernetic.Security.AuthManager` (currently stateful/session-based; not OIDC/JWKS verification)

Dev/test allows unauthenticated requests (a default tenant is assigned).

## Tenancy

- The gateway assigns `tenant_id` from the authenticated context.
- If `x-tenant-id` is provided, it must match the authenticated tenant (otherwise `403`).

## Endpoints

### POST `/v1/generate`

Routes a request to the S4 intelligence router.

- Body (JSON): `{"prompt": "...", "model": "default", "temperature": 0.7, "max_tokens": 2048, "stream": false}`
- Auth: required in production

### GET `/v1/events`

Server-Sent Events (SSE) stream.

- Query params:
  - `topics`: comma-separated topic patterns (e.g. `vsm.*,episode.*`)
  - `last_event_id`: optional resume token
- Auth: required in production

### POST `/telegram/webhook`

Telegram webhook receiver.

- In production, requires header `x-telegram-bot-api-secret-token` matching `TELEGRAM_WEBHOOK_SECRET`.

## Operational Notes

- Rate limiting and circuit breaking are applied to the `/v1/*` API pipeline.
- `/metrics` and `/health` are unauthenticated by default; restrict them at the network/load-balancer layer in production.

