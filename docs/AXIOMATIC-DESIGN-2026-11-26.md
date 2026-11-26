# cybernetic-amcp — Functional Requirements & MIT Axiomatic Design Analysis

Repo: [jmanhype/cybernetic-amcp](https://github.com/jmanhype/cybernetic-amcp) · Analyzed 2026-11-26 against main `ec6b8ee` (i.e. **after** the Nov 24–26 P0 remediation merges).
Method: Nam P. Suh's Axiomatic Design (MIT) — customer domain → functional domain (FRs) → physical domain (DPs) → process domain; **Axiom 1 (Independence)**: maintain the independence of the FRs; **Axiom 2 (Information)**: among designs satisfying Axiom 1, minimize information content *I* = log₂(1/*p*), where *p* is the probability that the DP actually delivers the FR within its design range.
Evidence base: README.md, docs/features.md, docs/architecture.md, the Craft Anything dossier ([docs/AUDIT-2026-11-23.md](https://github.com/jmanhype/cybernetic-amcp/blob/main/docs/AUDIT-2026-11-23.md), findings fnd_1–fnd_178+), the 39 unique GitHub issues (the repo's own requirement backlog), and the Nov 24–26 remediation receipts on [Issue #86](https://github.com/jmanhype/cybernetic-amcp/issues/86).

**How to read this document.** FRs are stated solution-neutrally ("what", never "how") and decomposed by zigzagging: each FR is expanded into sub-FRs only after its DP is chosen, and the sub-FRs are the requirements *that DP* must satisfy. A design is **uncoupled** if its design matrix is diagonal, **decoupled** if triangular (acceptable if DPs are set in the right order), **coupled** if it has off-diagonal terms that cannot be ordered away (violates Axiom 1). Three failure shapes recur in this codebase and get their own names below: a **phantom DP** (the DP exists as code but is never assembled into the system, so the FR row is empty in the running design), a **constant DP** (the "DP" is a hard-coded value, so the FR is not designed at all — it is asserted), and a **counterfeit DP** (the DP produces the right *shape* of output with none of the required *content*, so the matrix looks diagonal while the FR is undelivered — the worst case under Axiom 2, because *p* ≈ 0 while appearing to be 1).

---

## 1. Customer domain → FR0

Customer attributes (from README + features + the issue backlog): a single deployable OTP system that coordinates AI agents the way a viable organization regulates itself — Stafford Beer's Viable System Model — executing work through multiple LLM providers and external tools, under explicit policy and resource budgets, with distributed state, exposed through a protected HTTP edge, observable in operation, and shippable via Docker.

> **FR0 — Provide a viable, self-regulating AI coordination system**: execute user tasks through LLMs and tools, coordinated across semi-autonomous operational units, controlled within resource budgets, adapted by environmental intelligence, and governed by policy.
> **DP0** — the Cybernetic aMCP OTP application (VSM S1–S5 + cross-cutting subsystems).

Note the affinity: Beer's VSM and Suh's Axiom 1 are the same instinct in different vocabularies. VSM grants S1 units autonomy (independence of FRs) and adds S2 *only* to damp the oscillation that autonomy creates, S3 to allocate resources across units, S4/S5 to adapt and govern. A faithful VSM implementation should score unusually well on the Independence Axiom. The findings below are interesting precisely because most coupling in this codebase is *self-inflicted deviation from the VSM's own structure*, not a consequence of it.

## 2. Level 1 — FRs, DPs, and the design matrix

| # | Functional requirement (solution-neutral) | Design parameter (as implemented) | Audit status |
|---|---|---|---|
| FR1 | Execute operational work (accept tasks/commands; run agents; produce results) | DP1 — System1: `Operational`, `AgentSupervisor`, `Agents.TelegramAgent`, S1 MessageHandler | PARTIAL |
| FR2 | Coordinate operations (damp oscillation; allocate work across S1 units; signal overload) | DP2 — System2: `Coordinator` slot engine, S2 MessageHandler | PARTIAL → real since Nov 24 |
| FR3 | Control resources and performance (enforce rate/budget; audit operations; intervene on ill-health) | DP3 — System3: `RateLimiter`, `Control`, `ControlSupervisor` | PARTIAL → real since Nov 24 |
| FR4 | Sense and reason (obtain LLM inference; select provider; remember episodes) | DP4 — System4: `Intelligence`, `Router`, `Service`, `AMQPConsumer`, `Memory`, providers, `LLMBridge` | PARTIAL |
| FR5 | Govern (hold policy and identity; define procedures; override on algedonic signal) | DP5 — System5: `Policy` store, `SOPEngine`, `PolicyIntelligence` | PARTIAL |
| FR6 | Move messages between systems reliably (route, deliver, retry, order causally) | DP6 — Transport: `Transport.Behaviour`, AMQP (Connection/Topology/Publisher/Consumer), `Transport.InMemory` | PARTIAL (core BUILT) |
| FR7 | Maintain shared distributed state (context, memory, persistence) | DP7 — CRDT `ContextGraph`/`Graph`/`Cache`, S4 `Memory`, PostgreSQL/Ecto (`Repo`) | PARTIAL (#79 BUILT) |
| FR8 | Expose and invoke capabilities (register tools/capabilities; discover; plan; hand off execution) | DP8 — MCP layer (`Hermes.Registry`, `Handler`) + Capabilities (`Registry`, `MCPRouter`, `Planner.Collaboration`, `Execution.Handoff`, `LLMCDN`) | PARTIAL → result path real since Nov 24 |
| FR9 | Ingest and semantically organize external content | DP9 — Content: six CMS connectors + Google Drive, `Pipeline.Ingest`, `SemanticContainer`, `Buckets.CBCP` | PARTIAL |
| FR10 | Admit and protect external traffic (HTTP API; authenticate; prevent replay; throttle) | DP10 — Edge gateway (Phoenix endpoint/router/plugs) + Security (`AuthManager`, `NonceBloom`, JWT/JWKS) | PARTIAL |
| FR11 | Observe and assure (telemetry, metrics, alerts, admin visibility, verification) | DP11 — OpenTelemetry/PromEx/LiveDashboard, `CircuitBreakerAlerts`, Admin console, test suite + CI | PARTIAL |
| FR12 | Deploy and operate in production (package; configure; keep secrets) | DP12 — Docker Compose / K8s manifests, `config/*.exs`, `.env` | PARTIAL |

Level-1 design matrix (✕ = a DP materially affects that FR beyond its own diagonal):

|  | DP1 | DP2 | DP3 | DP4 | DP5 | DP6 | DP7 | DP8 | DP9 | DP10 | DP11 | DP12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **FR1** | ● | | ✕ | | | ✕ | | | | ✕ | | |
| **FR2** | | ● | | | | ✕ | | | | | | |
| **FR3** | | | ● | ✕ | ✕ | ✕ | | | | | | |
| **FR4** | | | ✕ | ● | ✕ | ✕ | ✕ | ✕ | | | | |
| **FR5** | | | | | ● | ✕ | | | | | | |
| **FR6** | | | | | | ● | | | | | | ✕ |
| **FR7** | | | | | | | ● | | ✕ | | | |
| **FR8** | | | ✕ | ✕ | | ✕ | | ● | | | | |
| **FR9** | | | | ✕ | | | ✕ | ✕ | ● | | | |
| **FR10** | | | ✕ | ✕ | | | | | | ● | | |
| **FR11** | | | | | | | | | | | ● | |
| **FR12** | | | | | | | | | | | | ● |

**Level-1 verdict: decoupled-leaning, not uncoupled — and the diagonal itself is the bigger problem.** The VSM skeleton keeps most FRs on their own DPs (FR6, FR7, FR11, FR12 are clean rows). The significant off-diagonal terms are enumerable and specific (§4). But Axiom 1 is a *necessary* condition, not a sufficient one: several diagonal entries are phantom, constant, or counterfeit DPs (§5), so the matrix *looks* closer to diagonal than the running system is. In AD terms the design's true matrix has **empty and fake diagonal cells**, which no amount of triangular ordering can fix — those FRs are simply not designed yet.

The most consequential off-diagonal terms at level 1:

- **FR4 × DP3 and FR3 × DP4 (a two-way coupling).** `Router` (DP4) must call DP3's `RateLimiter` for its budget check — acceptable, triangular, *if* all inference flows through `Router`. It doesn't: `LLMBridge` and `PolicyIntelligence` (also DP4/DP5) call providers directly, so FR3's budget sub-FR silently does not apply to part of FR4. One FR (budget control) is delivered or not depending on which internal path another FR takes — the textbook signature of a coupled design.
- **FR8 × DP3.** `Service` (in the S4/capability path) performs its *own* budget check via `Core.Security.RateLimiter` while `Router` uses `System3.RateLimiter` — two different DPs for the same sub-FR in two places (§3.2). Redundant, divergent control.
- **FR1 × DP10 / DP-root.** `TelegramAgent` is an S1 agent (FR1) but is started as a direct child of the root supervisor, not inside DP1's tree; separately, the edge Telegram webhook (DP10) dispatches its commands through Oban. One operational capability, two physical homes, neither inside the VSM hierarchy the architecture specifies.
- **FR6 × DP12 (was).** The effective transport — DP6's identity — was decided by a `config/runtime.exs` line (DP12) that overrode the test environment's chosen DP. Fixed 2026-11-26 (merge `ec6b8ee`) by pinning AMQP only outside `:test`.

## 3. Level 2 — zigzag decompositions

### 3.1 The VSM control loop (FR2, FR3, FR5)

| Sub-FR | DP | State |
|---|---|---|
| FR2.1 Reserve capacity per coordination lane; refuse or shed overload | `Coordinator` slot accounting (priority, aging, backpressure) | Real |
| FR2.2 Report a coordination outcome derived from actual grants | S2 `MessageHandler.coordinate_operation/2` | **Was a constant DP** (fixed `"coordinated"`, `["worker_1","worker_2"]`); real since Nov 24 (`aff1ff1`) — statuses now derive from slot grants |
| FR2.3 Release capacity when coordination completes | `Coordinator.release_slot/1` via `handle_coordination_complete` | Real since Nov 24 |
| FR3.1 Enforce per-consumer token budgets | `System3.RateLimiter` (token bucket) | Real, complete — the cleanest DP in the repo |
| FR3.2 Know each system's health from evidence | `ControlSupervisor.query_system_status/1` probing S1/S2 processes | **Was a constant DP** (`%{metrics: %{}, errors: []}`); real since Nov 24 (`e4bbe13`) |
| FR3.3 Judge health status from that evidence | `determine_health_status/1` | **Was a constant DP** (always `:healthy`, which made FR3.4 unreachable); real since Nov 24 |
| FR3.4 Intervene when health fails (incl. restarting the failed component) | `ControlSupervisor` intervention engine + `restart_component/1` | Real since Nov 24; the restart DP itself was *counterfeit* — addressed nonexistent child IDs (`:"system#{n}"`) and discarded the `{:error, :not_found}` result — fixed Nov 24 (`c3a174e`) |
| FR3.5 Produce a tamper-evident audit of operations (Issue #5) | S3 audit getters | **Constant DP, still open**: hard-coded constants (1000 ops, 0.98 success, `compliant: true`) — STUB per dossier |
| FR5.1 Hold and serve policy | `System5.Policy` store | Real |
| FR5.2 Execute standard operating procedures | `SOPEngine.run_steps` | Stub (dossier) |
| FR5.3 Escalate algedonic (pain/pleasure) signals to intervention | *three partial DPs*: S1 process-dictionary → `s4.algedonic` topic; S4 handler → telemetry only; `ControlSupervisor` `{:algedonic_signal,…}` path | **Coupled by fragmentation**: one FR, three DPs, no complete path connects them (dossier, VSM final) |

Sub-matrix for FR3 is diagonal *now* — this branch went from the worst in the system (two constant DPs + one counterfeit DP stacked in a single causal chain, so the whole control loop was decorative) to genuinely decoupled by the Nov 24 merges. It is the clearest before/after in the repo: **the Nov 24 work was, in AD terms, converting constant/counterfeit diagonal entries into real DPs.**

### 3.2 Intelligence and inference (FR4)

| Sub-FR | DP | State |
|---|---|---|
| FR4.1 Classify the work (episode kind) | `Service` classification (kind/keywords) | Real |
| FR4.2 Select a provider chain (capability, cost, health, breaker state) | `Router` provider-chain selection | Real |
| FR4.3 Enforce the inference budget *for every call* | `Router.check_budget/2` → `System3.RateLimiter` | **Coupled**: `LLMBridge` bypasses `Router` entirely and calls `provider.analyze_episode/2` directly; `PolicyIntelligence` likewise; `Service` uses a *different* limiter (`Core.Security.RateLimiter`) |
| FR4.4 Degrade safely when no provider is configured | `Providers.Null` | **Counterfeit DP**: returns a *successful* no-op (empty recommendations), so FR4 reports success while delivering nothing — the single most dangerous cell in the design under Axiom 2 |
| FR4.5 Remember episodes across surfaces (Issue #13) | S4 `Memory` storage | Real storage; cross-surface specifics PARTIAL |
| FR4.6 Embed content for semantic operations | `generate_embedding` fallbacks | **Counterfeit DP** (shared with FR8.2/FR9.3, §3.4) |

### 3.3 Capabilities and tools (FR8)

| Sub-FR | DP | State |
|---|---|---|
| FR8.1 Register tools and capabilities with validated manifests | Hermes `Registry`; Capabilities `Registry` + hand-rolled `Validation` | Real (two parallel registries — a redundancy, see §4) |
| FR8.2 Discover capabilities *by meaning* | `Registry.discover/match_semantic` | **Counterfeit + wrong complexity class**: embeddings are SHA-256 bytes ÷ 255 ("Placeholder — would use ReqLLM in production"); retrieval is an exhaustive O(n) cosine scan, threshold 0.8 |
| FR8.3 Invoke a tool and **return its result to the caller** | Hermes `Registry.invoke_tool` → `Handler` | **Was counterfeit**: replied with the invocation ID and discarded the result on completion; real since Nov 24 (`1b19328`) |
| FR8.4 Plan multi-step work from a goal | `Planner.Collaboration` | **Scope mismatch**: a contribution coordinator (sorts submitted steps by priority, flattens) — no goal decomposition, capability lookup, or step execution. The DP answers a different, smaller FR than the one stated |
| FR8.5 Hand off execution | `Execution.Handoff` | PARTIAL (dossier) |
| FR8.6 Speak the MCP protocol to external clients | `MCP.Core`, `Server`, `HermesClient`, `MAGGAdapter` | **Stubs**: `Core.call_tool` returns a hard-coded "Mock result" (its tests assert the mock); `HermesClient.call_tool → {:error, :not_implemented}`; `MAGGAdapter.call → {:ok, :stub}`. The live path (AMQP Consumer → `Handler` → `Registry`) works since Nov 24, but the protocol-facing layer is not designed |

### 3.4 Content (FR9)

| Sub-FR | DP | State |
|---|---|---|
| FR9.1 Fetch content from each CMS (6 connectors + Drive) | Connector modules (WP REST, JSON:API, Ghost CDA, Sanity, Strapi, Contentful CDA/Sync, Drive) | Real, API-accurate implementations |
| FR9.2 Assemble the content subsystem into the running system | `Content.Supervisor` as an application child | **Was a phantom DP**: supervisor existed but was not started (whole subsystem dark); wired Nov 24 (`50c3e85`). `list_connectors/0` still omits Drupal/Ghost/Sanity/Strapi/Contentful — the registry sub-DP under-reports the DPs that exist |
| FR9.3 Store content semantically and retrieve by similarity | `SemanticContainer` + `hnsw_index` | Container/registry real; **search is a broken diagonal**: `search_similar → {:error, :hnsw_not_configured}` with no fallback, embeddings counterfeit (§3.2 FR4.6), metadata ETS-only (restart orphans content) |
| FR9.4 Ingest arbitrary URLs safely | `Pipeline.Ingest` (SSRF-pinned fetch, size caps) | Real fetch/normalize; moduledoc claims S3 fetch, entity extraction, Oban queueing, retry/backoff — none implemented (documentation overstates the DP, an Axiom-2 hazard: consumers design against FRs the DP doesn't deliver) |
| FR9.5 Track changes incrementally | Connectors' `get_changes` / sync tokens | **Counterfeit in part**: Contentful discards `nextSyncUrl`, Drive discards `startPageToken` — every sync is a full refetch wearing an incremental interface; deletions counted but never applied; changed items create new containers instead of updating (orphans) |

### 3.5 Transport (FR6)

| Sub-FR | DP | State |
|---|---|---|
| FR6.1 Publish/consume over AMQP with declared topology | Connection/Topology/Publisher/Consumer | Real core (15 queues, 17 bindings) — but a parallel, consumer-less `cyb.sN.*` queue set coexists with the `vsm.sN.*` set |
| FR6.2 Address inter-system messages unambiguously | Routing-key scheme | **Coupled by ambiguity**: three naming schemes coexist (`vsm.systemN.*`, `cyb.commands/events` with `sN.*` keys, `cyb.s4.llm`); nothing in scope consumes the `s2.coordinate` / `s4.intelligence` / `s4.algedonic` topics — the documented S1→S2→S3→S4→S5 flow is not closed by addressing |
| FR6.3 Retry failed deliveries with backoff | `RetryHelper.with_retry/5`; Consumer retry path | RetryHelper is a **phantom DP** (fully written, referenced by nothing); the Consumer's live retry republishes to a key with no binding, so retries land in `events.stream` |
| FR6.4 Track causality across messages (Issue #3) | `Causality.put_headers/3` | **Counterfeit**: appends wall-clock time labelled as a Lamport clock; no increment/merge/compare; no caller in scope |
| FR6.5 Select transport per environment | `Transport.Behaviour.current_transport/0` ← `:transport` config | **Was coupled to DP12** (runtime.exs override); fixed 2026-11-26. A latent shape bug remains: `config.exs` sets `:transport` to a keyword list while `current_transport/0` calls `.publish` on the value as a module — only runtime.exs's bare-module pin masks it |

## 4. Independence Axiom — the coupling register

Numbered for reference; each entry names the FRs whose independence fails and the evidence.

1. **Budget bypass (FR3 × FR4).** Two of three inference entry points (`LLMBridge`, `PolicyIntelligence`) skip the one DP that enforces FR3's budget. Independence fails because FR4's internal path choice changes whether FR3 is delivered. *Fix shape: single choke point — all provider calls through `Router`.* (Dossier, LLM routing final; Issue #86 P1.)
2. **Duplicate budget DPs (FR3 internal).** `System3.RateLimiter` vs `Core.Security.RateLimiter` enforce "the budget" in different paths with different semantics. Two DPs for one sub-FR cannot both be the diagonal entry; tuning one silently un-tunes the other.
3. **Algedonic fragmentation (FR5.3 × FR3.4 × FR4).** The pain/pleasure loop — VSM's highest-priority control channel — exists as three unconnected partial DPs. No ordering of DP settings closes it; it needs one DP to own the path end-to-end.
4. **Shared counterfeit embedding DP (FR4.6 × FR8.2 × FR9.3).** One placeholder (SHA-256-as-vector) serves three FRs in three subsystems. It couples them (change it anywhere, semantics shift everywhere) while delivering none of them — coupling *and* information failure in a single cell.
5. **Missing shared DP (FR9.3 × FR8.2).** Both semantic-search FRs depend on an HNSW index DP that does not exist in the capabilities scope (`{:error, :hnsw_not_configured}` / `{:error, :hnsw_not_configured}` paths). Two FR rows share an absent diagonal entry.
6. **Addressing ambiguity (FR6.2 × all VSM FRs).** Three routing schemes mean every inter-system FR's delivery depends on which scheme the sender happened to use — a system-wide coupling term in the transport row.
7. **Placement violation (FR1 × DP-root).** `TelegramAgent` outside DP1's supervision subtree couples FR1's lifecycle to the root tree and to DP10's webhook path.
8. **Config-shape coupling (FR6.5 × FR12).** `:transport` has two incompatible representations (keyword list vs module) in two config files; the design works only because a third line overwrites one with the other. The Nov 26 fix removed the harmful instance, not the shape ambiguity.
9. **Parallel registries (FR8.1 internal).** Hermes `Registry` and Capabilities `Registry` both register capabilities/tools with separate validation. Redundant DPs for one FR: divergence risk, doubled information content.
10. **Edge breaker that cannot trip (FR10 × FR11).** `Plugs.CircuitBreaker` *reads* `AdaptiveCircuitBreaker` state but never records success/failure, so within the edge nothing can change the state it reads — FR10's protection depends on DPs outside its row recording events they may not record. (Dossier, edge final.)

**What is genuinely uncoupled (credit where due):** `System3.RateLimiter` as a DP — one FR, one DP, reused by Router, gateway plug, and Telegram without semantic drift (the gateway plug's per-tenant keying is a parameter, not a fork). The AMQP transport core. `SemanticContainer`'s pluggable `storage_adapter` (an adapter seam is exactly how AD decouples an FR from a volatile DP). Ecto/`Repo` (#79, the audit's only BUILT verdict). These prove the codebase can produce diagonal design when a component is finished; the coupling concentrates in *unfinished* components, which is the pattern §5 explains.

## 5. The three failure shapes (this repo's real Axiom-1 problem)

Textbook coupling is not this design's main defect. The dominant defect is diagonal cells that are not real DPs:

- **Phantom DPs** (exist as code, absent from the assembled system): `Content.Supervisor` and `Capabilities.Supervisor` and S3 `ControlSupervisor` before Nov 24; `RetryHelper`; `Tracing`. Each silently zeroes an FR row. AD assumes DPs are *in* the design; a supervision tree is this system's assembly step, and anything not in it is not a DP, whatever the source tree says.
- **Constant DPs** (the FR is asserted, not designed): S2 coordination results (fixed Nov 24), S3 health + status inputs (fixed Nov 24), S3 audit getters (Issue #5, **still open**), `Server`'s hard-coded VSM answers (`agents: 5`, …), `PolicyIntelligence` constants. A constant "DP" has no adjustable parameter, so the design equation FR = A·DP degenerates: the FR takes whatever value the constant says, in all operating conditions.
- **Counterfeit DPs** (right shape, no content): SHA-256 pseudo-embeddings; `Providers.Null` success-noop; MCP invocation-ID-as-result (fixed Nov 24); Causality's wall-clock "Lamport" headers; Contentful/Drive sync tokens discarded; Twitter Spaces `poll_space_status → {:ok, :live}` always (Issue #22, STUB). Counterfeits are worse than missing DPs under Axiom 2: a missing DP has known *p* = 0; a counterfeit has *p* ≈ 0 *while being counted as 1* by every downstream consumer, corrupting every information-content estimate built on it.

## 6. Information Axiom — where *p* is low, zero, or unknowable

Axiom 2 only ranks designs that pass Axiom 1, but its lens — *I* = log₂(1/*p*) per FR — is the right severity ordering for the backlog:

| FR | *p* assessment | *I* | Basis |
|---|---|---|---|
| FR8.2 / FR9.3 semantic discovery & search | ≈ 0 for true semantic match: hash bytes carry no semantic signal; system range (hash space) and design range (meaning) do not overlap | → ∞ | fnd_141/142; `search_similar` hard-errors without HNSW |
| FR4.4 safe degradation | 0 *and masked*: Null returns success, so the *measured* p̂ = 1 while true p = 0 | ∞, hidden | LLM routing final |
| FR5.2 SOP execution; FR8.6 MCP protocol surface; FR3.5 audit | ≈ 0 (stubs/constants) | → ∞ | Dossier verdicts STUB |
| FR6.4 causality | ≈ 0 (no caller; not a Lamport clock) | → ∞ | fnd_38 |
| FR9.5 incremental sync | Low: correct counts, wrong effects (no updates, no deletes, full refetch) | High | Connectors A/B finals |
| FR2/FR3 control loop | Was ∞ (constant DPs); now *measurable* — the Nov 24 tests assert real grants/probes/restarts | Dropped sharply | Merges `aff1ff1`, `e4bbe13`, `c3a174e` |
| FR8.3 tool-result return | Was ≈ 0; now real with tests | Dropped sharply | Merge `1b19328` |
| FR6.5 transport selection (test) | Was silently wrong-DP; now correct and probed | Dropped | Merge `0d9db49` |
| FR1, FR5.1, FR7, FR10, FR11 (bulk) | **Unknowable**: the measurement DP is weak — 1144 tests with 60–63 baseline failures, some suites passing with zero assertions, GoldRush smoke tests asserting `true`, golden tests skipped, coverage threshold 24%, no dedicated connector/breaker test files | *I* cannot be computed | Tests final; suite baselines Nov 24–26 |

The last row is the deepest Axiom-2 finding: **for most FRs the system cannot currently measure its own probability of success.** Axiom 2 presumes you can compare system range to design range; a suite that passes vacuously makes every *I* estimate fiction. Fixing weak tests (Issue #86 P2) is therefore not hygiene — it is the precondition for applying Axiom 2 at all.

## 7. Verdict

- **Architecture (intent): decoupled, VSM-shaped, sound.** The level-1 matrix is close to triangular; Beer's structure and Suh's first axiom agree, and the finished components (RateLimiter, transport core, Repo, container storage seam) are genuinely diagonal.
- **Implementation (as built, Nov 23): coupled in ten enumerated places, with roughly a third of the diagonal phantom, constant, or counterfeit.** The system presented the *shape* of the VSM design while several of its load-bearing FRs were undelivered.
- **Trajectory (Nov 24–26): the remediation is exactly an Axiomatic-Design repair program**, whether or not it was named that way: P0 converted constant/counterfeit DPs into real ones (S2, S3, MCP results) and assembled phantom DPs into the tree (supervisors); the transport fix removed a config coupling. Every P0 checkbox on Issue #86 corresponds to a §4/§5 entry above.
- **Remaining work, in Axiom order:** (1) finish Axiom 1 — kill the budget bypass (#1), unify the budget DP (#2), close the algedonic path (#3), replace the shared embedding counterfeit with one real DP serving FR4.6/8.2/9.3 plus the missing HNSW DP (#4/#5, Issue #86 P1), single addressing scheme (#6); (2) replace remaining constant/counterfeit DPs (audit #5→FR3.5, SOP engine, MCP protocol layer, WASM validator — implement it or delete the FR, both are valid AD moves); (3) then Axiom 2 — make *p* measurable (weak-test P2) and only then optimize information content (real embeddings' quality, planner scope honesty: either grow the DP to the FR or restate FR8.4 to what the DP actually does).

*Prepared from the audit evidence base; no new code was executed for this analysis. FR/DP status reflects main `ec6b8ee` (2026-11-26).*
