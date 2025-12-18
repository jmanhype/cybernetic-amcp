---
description: "Full Spec Kit flow with quality gates: constitution→specify→clarify→plan→contract→checklist→tasks→analyze→implement. Usage: /speckit-workflow-v2 <brief> [--domains 'security,accessibility,performance'] [--strict] [--auto] [--parallel]"
# Purpose: Orchestrate ALL major Spec Kit features—including domain checklists and contract-driven development—via SlashCommand without manual chaining.
# Tools: Bash only for sanity checks; the heavy lifting is done by slash commands the agent invokes autonomously.
allowed-tools:
  - Bash(specify:*)
  - mcp__specmatic__*
---

# Speckit Workflow v2 (Feature-complete)

## Objective

Convert "$ARGUMENTS" into a validated spec-driven change using **every relevant Spec Kit phase**:
constitution → specify → (clarify) → plan → **contract** → **checklist** → tasks → analyze → implement.

## Prechecks
- If /speckit.* commands aren't visible in /help:
  !uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
  !specify init --here --ai claude
  !specify check

## Inputs
- `$ARGUMENTS` = brief + optional flags:
  - `--domains "<csv>"` e.g., "security,privacy,accessibility,performance,observability"
  - `--strict`          fail the run if checklist/analyze/contract gates don't pass
  - `--auto`            proceed without asking between gates (unless a blocking ambiguity is detected)
  - `--parallel`        use specialized sub-agents for parallel backend/frontend implementation

## Flow

### 1) Constitution (first run only)
   - If no principles exist, run:
     /speckit.constitution Create principles for code quality, testing standards, UX consistency, performance/SLOs, security, accessibility.

### 2) Specify (WHAT/WHY)
   - Run:
     /speckit.specify $ARGUMENTS
   - Keep tech decisions out of the spec.

### 3) Clarify (targeted; only if needed)
   - If the spec is underspecified, run:
     /speckit.clarify Ask only focused questions to resolve ambiguities blocking the plan.

### 4) Plan (HOW)
   - Run:
     /speckit.plan Draft the technical plan aligned to the spec: architecture, data model, interfaces, testing/observability, performance budgets, risks.
   - If API endpoints are defined, ensure OpenAPI spec is created in `specs/<feature>/contracts/openapi.yaml`

### 5) **Contract Validation (API gate)** - NEW
   - If `specs/<feature>/contracts/openapi.yaml` exists:
     - Use `openapi-spec-author` agent or run directly:
       ```bash
       specmatic backward-compatibility-check --target-path ./specs/<feature>/contracts/openapi.yaml
       ```
     - **Rules**:
       - Adding optional fields: ✅ ALLOWED
       - Adding new endpoints: ✅ ALLOWED
       - Removing endpoints/fields: ❌ BREAKING
       - Changing field types: ❌ BREAKING
     - If `--strict` and breaking changes detected → **stop with actionable summary**
     - For WIP APIs, add `tags: ["WIP"]` to bypass breaking change failures

### 6) **Checklist (quality gate)**
   - Build the domain list:
     - If `--domains` present, use it; otherwise default to: security, privacy, accessibility, performance, observability, compliance, UX.
   - Run:
     /speckit.checklist Generate a checklist for the chosen domains. Identify missing requirements, non-goals, acceptance criteria, and risky gaps.
   - If items remain unclear or unchecked:
     - Loop: `/speckit.clarify` to resolve; update spec/plan; rerun `/speckit.checklist`.
   - If `--strict` and checklist is not green → **stop with actionable summary**.

### 7) Tasks (make it executable)
   - Run:
     /speckit.tasks
   - Require small, verifiable tasks with dependencies, Definition of Done, and verification steps.
   - Tasks should be organized by user story for parallel execution

### 8) Analyze (consistency gate)
   - Run:
     /speckit.analyze
   - If inconsistencies between spec/plan/tasks remain:
     - Repair artifacts; rerun `/speckit.tasks`; rerun `/speckit.analyze`.
   - If `--strict` and analysis isn't clean → **stop with actionable summary**.

### 9) Implement (do the work)
   - Run:
     /speckit.implement

   **If `--parallel` flag present**, use specialized sub-agents:

   ```
   Phase 1: API Design
   └── openapi-spec-author agent validates/updates contracts

   Phase 2: Parallel Implementation
   ├── backend-api-engineer (TDD, Specmatic contract tests)
   └── frontend-react-engineer (TDD, Specmatic mock server)
       └── Both work from same OpenAPI contract simultaneously

   Phase 3: Integration
   └── integration-tester (Playwright E2E, smoke tests)
   ```

   **Sub-agent capabilities**:
   | Agent | Role | Tools |
   |-------|------|-------|
   | `openapi-spec-author` | API design, backward compatibility | Specmatic MCP |
   | `backend-api-engineer` | Backend TDD, contract testing | Specmatic MCP |
   | `frontend-react-engineer` | React/TypeScript, accessibility | Specmatic + Playwright |
   | `integration-tester` | E2E, performance, smoke tests | Playwright MCP |

   Each sub-agent:
   - Invokes `project-standards` skill for constitution guidance
   - Updates Beads with progress (`bd update`, `bd note`)
   - Follows TDD (tests first, then implementation)

### 10) Report
   - Emit a concise summary: phases executed, artifacts changed, outstanding TODOs, and what to do next if gates failed.
   - Include contract validation status
   - Include sub-agent completion status (if `--parallel`)

## Notes
- Use SlashCommand to **invoke** each command; do not merely print them.
- Ask ≤5 questions only when ambiguity blocks a gate and `--auto` is not present.
- Contract validation uses Specmatic MCP when available, falls back to CLI.

## Success
- Spec articulates users, journeys, outcomes, and success criteria.
- Plan covers stack, architecture, data model, testing, observability, and perf budgets.
- **Contract is backward compatible (no breaking changes).**
- Checklist is green across requested domains.
- Analyze finds no cross-artifact contradictions.
- Implementation completes or yields actionable failures with verification steps.
- **If `--parallel`: Backend, frontend, and integration all pass independently.**
