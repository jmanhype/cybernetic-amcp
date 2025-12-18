---
description: "Execute the implementation plan by processing tasks from tasks.md. Usage: /speckit.implement [--parallel]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - mcp__specmatic__*
  - mcp__playwright__*
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. Run `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks` from repo root and parse FEATURE_DIR and AVAILABLE_DOCS list. All paths must be absolute. For single quotes in args like "I'm Groot", use escape syntax: e.g 'I'\''m Groot' (or double-quote if possible: "I'm Groot").

2. **MANDATORY: Run Phase Gate** before starting implementation:
   ```bash
   ./.claude/hooks/phase-gate.sh tasks implement
   ```
   - This ensures all existing tests pass before implementation begins
   - If the gate fails, **STOP** and fix issues before proceeding
   - Display the gate output to the user

3. **Verify consistency validation** (IMPORTANT):
   - Check if the user has run `/speckit.analyze` to validate consistency between spec.md, plan.md, and tasks.md
   - If there's no evidence of analyze having been run (ask user or check conversation history), **recommend** running `/speckit.analyze` first
   - **Why this matters**: Analyze catches missing requirements, scope creep, and graceful degradation gaps before implementation begins
   - However, do NOT block implementation if user chooses to proceed without analyze

4. **Check Linear sync status** (if Linear integration configured):
   - Check for `.specify/linear-mapping.json`
   - If exists, display current sync status
   - Suggest running `/speckit.linear.sync --from-linear` to pull latest status
   - Continue with implementation regardless

5. **Check checklists status** (if FEATURE_DIR/checklists/ exists):
   - Scan all checklist files in the checklists/ directory
   - For each checklist, count:
     - Total items: All lines matching `- [ ]` or `- [X]` or `- [x]`
     - Completed items: Lines matching `- [X]` or `- [x]`
     - Incomplete items: Lines matching `- [ ]`
   - Create a status table:

     ```text
     | Checklist | Total | Completed | Incomplete | Status |
     |-----------|-------|-----------|------------|--------|
     | ux.md     | 12    | 12        | 0          | ✓ PASS |
     | test.md   | 8     | 5         | 3          | ✗ FAIL |
     | security.md | 6   | 6         | 0          | ✓ PASS |
     ```

   - Calculate overall status:
     - **PASS**: All checklists have 0 incomplete items
     - **FAIL**: One or more checklists have incomplete items

   - **If any checklist is incomplete**:
     - Display the table with incomplete item counts
     - **STOP** and ask: "Some checklists are incomplete. Do you want to proceed with implementation anyway? (yes/no)"
     - Wait for user response before continuing
     - If user says "no" or "wait" or "stop", halt execution
     - If user says "yes" or "proceed" or "continue", proceed to step 6

   - **If all checklists are complete**:
     - Display the table showing all checklists passed
     - Automatically proceed to step 6

6. Load and analyze the implementation context:
   - **REQUIRED**: Read tasks.md for the complete task list and execution plan
   - **REQUIRED**: Read plan.md for tech stack, architecture, and file structure
   - **IF EXISTS**: Read data-model.md for entities and relationships
   - **IF EXISTS**: Read contracts/ for API specifications and test requirements
   - **IF EXISTS**: Read research.md for technical decisions and constraints
   - **IF EXISTS**: Read quickstart.md for integration scenarios

7. **Execution Mode Selection**:

   Check if `--parallel` flag is present in `$ARGUMENTS`:

   ### A) Standard Mode (default)
   - Execute tasks sequentially in main thread
   - Follow standard task ordering from tasks.md
   - Continue to step 8

   ### B) Parallel Mode (`--parallel` flag)
   - Use specialized sub-agents for contract-driven parallel development
   - Enables backend and frontend to work simultaneously from OpenAPI contract

   **Sub-Agent Orchestration Flow:**

   ```
   ┌─────────────────────────────────────────────────────────────────┐
   │                    PARALLEL IMPLEMENTATION                       │
   ├─────────────────────────────────────────────────────────────────┤
   │                                                                 │
   │  Phase 1: Contract Validation                                   │
   │  └── openapi-spec-author agent                                  │
   │      ├── Validates OpenAPI spec exists                          │
   │      ├── Runs backward compatibility check (Specmatic)          │
   │      └── Updates contracts if needed                            │
   │                                                                 │
   │  Phase 2: Parallel Implementation                               │
   │  ├── backend-api-engineer ─────────┐                           │
   │  │   ├── Uses Specmatic for        │                           │
   │  │   │   contract testing          │  PARALLEL                 │
   │  │   ├── Follows TDD               │  (same OpenAPI            │
   │  │   └── Updates Beads             │   contract)               │
   │  │                                 │                           │
   │  └── frontend-react-engineer ──────┘                           │
   │      ├── Uses Specmatic stub                                    │
   │      │   server for mocking                                     │
   │      ├── Follows TDD                                            │
   │      └── Updates Beads                                          │
   │                                                                 │
   │  Phase 3: Integration Testing                                   │
   │  └── integration-tester agent                                   │
   │      ├── E2E tests with Playwright                              │
   │      ├── Smoke tests                                            │
   │      ├── Performance validation                                 │
   │      └── Final Beads updates                                    │
   │                                                                 │
   └─────────────────────────────────────────────────────────────────┘
   ```

   **Sub-Agent Invocation:**

   Use the Task tool to spawn each sub-agent:

   ```
   # Phase 1: API Contract Validation
   Task(subagent_type="openapi-spec-author", prompt="Validate and finalize OpenAPI contracts...")

   # Phase 2: Parallel Backend + Frontend (spawn together)
   Task(subagent_type="backend-api-engineer", prompt="Implement backend tasks...")
   Task(subagent_type="frontend-react-engineer", prompt="Implement frontend tasks...")

   # Phase 3: Integration (after Phase 2 completes)
   Task(subagent_type="integration-tester", prompt="Run E2E integration tests...")
   ```

   **Sub-Agent Task Assignment:**

   | Agent | Tasks to Assign |
   |-------|-----------------|
   | `openapi-spec-author` | Tasks in contracts/, API design tasks |
   | `backend-api-engineer` | Tasks with `backend/`, `api/`, `src/services/`, `src/models/` |
   | `frontend-react-engineer` | Tasks with `frontend/`, `src/components/`, `src/pages/` |
   | `integration-tester` | Tasks with `tests/e2e/`, `tests/integration/`, smoke tests |

   **Beads Coordination:**

   Each sub-agent updates Beads independently:
   ```bash
   # Before starting task
   bd update <task-id> --status in-progress

   # During implementation (discoveries)
   bd note <task-id> "Found edge case: ..."

   # After completing task
   bd update <task-id> --status done
   ```

   **Contract as Source of Truth:**

   - `specs/<feature>/contracts/openapi.yaml` is THE contract
   - Backend implements TO the contract (Specmatic validates)
   - Frontend mocks FROM the contract (Specmatic stub server)
   - Integration verifies THROUGH the contract (E2E tests)

   After parallel execution completes, continue to step 15 (Completion validation).

8. **Project Setup Verification**:
   - **REQUIRED**: Create/verify ignore files based on actual project setup:

   **Detection & Creation Logic**:
   - Check if the following command succeeds to determine if the repository is a git repo (create/verify .gitignore if so):

     ```sh
     git rev-parse --git-dir 2>/dev/null
     ```

   - Check if Dockerfile* exists or Docker in plan.md → create/verify .dockerignore
   - Check if .eslintrc* exists → create/verify .eslintignore
   - Check if eslint.config.* exists → ensure the config's `ignores` entries cover required patterns
   - Check if .prettierrc* exists → create/verify .prettierignore
   - Check if .npmrc or package.json exists → create/verify .npmignore (if publishing)
   - Check if terraform files (*.tf) exist → create/verify .terraformignore
   - Check if .helmignore needed (helm charts present) → create/verify .helmignore

   **If ignore file already exists**: Verify it contains essential patterns, append missing critical patterns only
   **If ignore file missing**: Create with full pattern set for detected technology

   **Common Patterns by Technology** (from plan.md tech stack):
   - **Node.js/JavaScript/TypeScript**: `node_modules/`, `dist/`, `build/`, `*.log`, `.env*`
   - **Python**: `__pycache__/`, `*.pyc`, `.venv/`, `venv/`, `dist/`, `*.egg-info/`
   - **Java**: `target/`, `*.class`, `*.jar`, `.gradle/`, `build/`
   - **C#/.NET**: `bin/`, `obj/`, `*.user`, `*.suo`, `packages/`
   - **Go**: `*.exe`, `*.test`, `vendor/`, `*.out`
   - **Ruby**: `.bundle/`, `log/`, `tmp/`, `*.gem`, `vendor/bundle/`
   - **PHP**: `vendor/`, `*.log`, `*.cache`, `*.env`
   - **Rust**: `target/`, `debug/`, `release/`, `*.rs.bk`, `*.rlib`, `*.prof*`, `.idea/`, `*.log`, `.env*`
   - **Kotlin**: `build/`, `out/`, `.gradle/`, `.idea/`, `*.class`, `*.jar`, `*.iml`, `*.log`, `.env*`
   - **C++**: `build/`, `bin/`, `obj/`, `out/`, `*.o`, `*.so`, `*.a`, `*.exe`, `*.dll`, `.idea/`, `*.log`, `.env*`
   - **C**: `build/`, `bin/`, `obj/`, `out/`, `*.o`, `*.a`, `*.so`, `*.exe`, `Makefile`, `config.log`, `.idea/`, `*.log`, `.env*`
   - **Swift**: `.build/`, `DerivedData/`, `*.swiftpm/`, `Packages/`
   - **R**: `.Rproj.user/`, `.Rhistory`, `.RData`, `.Ruserdata`, `*.Rproj`, `packrat/`, `renv/`
   - **Universal**: `.DS_Store`, `Thumbs.db`, `*.tmp`, `*.swp`, `.vscode/`, `.idea/`

   **Tool-Specific Patterns**:
   - **Docker**: `node_modules/`, `.git/`, `Dockerfile*`, `.dockerignore`, `*.log*`, `.env*`, `coverage/`
   - **ESLint**: `node_modules/`, `dist/`, `build/`, `coverage/`, `*.min.js`
   - **Prettier**: `node_modules/`, `dist/`, `build/`, `coverage/`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`
   - **Terraform**: `.terraform/`, `*.tfstate*`, `*.tfvars`, `.terraform.lock.hcl`
   - **Kubernetes/k8s**: `*.secret.yaml`, `secrets/`, `.kube/`, `kubeconfig*`, `*.key`, `*.crt`

9. Parse tasks.md structure and extract:
   - **Task phases**: Setup, Tests, Core, Integration, Polish
   - **Task dependencies**: Sequential vs parallel execution rules
   - **Task details**: ID, description, file paths, parallel markers [P]
   - **Execution flow**: Order and dependency requirements
   - **Linear IDs**: Extract any `<!-- LINEAR:TEAM-XXX -->` markers

10. Execute implementation following the task plan:
    - **Phase-by-phase execution**: Complete each phase before moving to the next
    - **Respect dependencies**: Run sequential tasks in order, parallel tasks [P] can run together
    - **Follow TDD approach**: Execute test tasks before their corresponding implementation tasks
    - **File-based coordination**: Tasks affecting the same files must run sequentially
    - **Validation checkpoints**: Verify each phase completion before proceeding

11. Implementation execution rules:
    - **Setup first**: Initialize project structure, dependencies, configuration
    - **Tests before code**: If you need to write tests for contracts, entities, and integration scenarios
    - **Core development**: Implement models, services, CLI commands, endpoints
    - **Integration work**: Database connections, middleware, logging, external services
    - **Polish and validation**: Unit tests, performance optimization, documentation

12. Progress tracking and error handling:
    - Report progress after each completed task
    - Halt execution if any non-parallel task fails
    - For parallel tasks [P], continue with successful tasks, report failed ones
    - Provide clear error messages with context for debugging
    - Suggest next steps if implementation cannot proceed
    - **IMPORTANT** For completed tasks, make sure to mark the task off as [X] in the tasks file.

13. **TEST GATE (MANDATORY)** - After EACH task:

    **Requirements**:
    - 100% unit tests passing
    - 100% integration tests passing (if applicable)
    - 100% smoke tests passing (if applicable)
    - 100% code coverage (configurable via SPECKIT_COVERAGE_THRESHOLD)

    **After each task**:
    - The PostToolUse hook automatically runs `.claude/hooks/test-gate.sh`
    - If gate fails:
      - **DO NOT mark task complete**
      - **DO NOT proceed to next task**
      - Fix the failing test/code first
      - Re-run tests until 100% pass

    **After each user story completes**:
    - Run integration tests for that story explicitly
    - Verify 100% pass rate

    **After each phase completes**:
    - Run full test suite (unit + integration + smoke)
    - Verify coverage meets threshold
    - Any regression = STOP and fix

    **Before marking feature complete**:
    - Run: `./.claude/hooks/phase-gate.sh implement complete`
    - This runs the FULL test suite with coverage check
    - ALL tests must pass at 100%
    - Coverage must meet threshold (default 100%)

14. **Linear Sync** (if configured):
    - After each task completion, if Linear mapping exists:
      - Update task status in tasks.md with `[x]`
      - Optionally sync to Linear (suggest `/speckit.linear.sync`)
    - At feature completion, push final status to Linear

15. Completion validation:
    - Verify all required tasks are completed
    - Check that implemented features match the original specification
    - Validate that tests pass and coverage meets requirements
    - Confirm the implementation follows the technical plan
    - Report final status with summary of completed work

    **Standard Mode Display:**
    ```
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ✅ IMPLEMENTATION COMPLETE

       Tasks:       12/12 complete
       Unit Tests:  ✓ 100% pass
       Integration: ✓ 100% pass
       Smoke Tests: ✓ 100% pass
       Coverage:    ✓ 100%

       Linear: TEAM-123 (synced)
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ```

    **Parallel Mode Display (`--parallel`):**
    ```
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ✅ PARALLEL IMPLEMENTATION COMPLETE

       Sub-Agents:
       ├── openapi-spec-author:     ✓ Contract validated
       ├── backend-api-engineer:    ✓ 6/6 tasks complete
       ├── frontend-react-engineer: ✓ 5/5 tasks complete
       └── integration-tester:      ✓ E2E passed

       Contract:    ✓ Backward compatible
       Unit Tests:  ✓ 100% pass (backend + frontend)
       Integration: ✓ 100% pass
       E2E Tests:   ✓ 100% pass
       Coverage:    ✓ 100%

       Beads: All tasks synced
       Linear: TEAM-123 (synced)
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ```

Note: This command assumes a complete task breakdown exists in tasks.md. If tasks are incomplete or missing, suggest running `/speckit.tasks` first to regenerate the task list.
