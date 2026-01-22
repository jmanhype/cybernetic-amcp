# Implement Dynamic System Tracing

## Overview
Implement a dynamic tracing system using `:telemetry` to capture actual runtime execution paths. This overcomes limitations of static analysis (Item 003) which missed dynamic dispatch patterns.

## Goals
1.  **Capture Traces**: Record execution flow from entry points (HTTP, AMQP) to deep internal functions.
2.  **Correlate Events**: Use Trace IDs to stitch disjoint events (e.g., HTTP request -> AMQP publish -> AMQP consume) into a single cohesive story.
3.  **Validate Archeology**: Compare dynamic traces against static call graphs to identify "invisible" dependencies.

## Phases

### Phase 1: Telemetry Spans
- Create `Cybernetic.Archeology.DynamicTracer` module.
- Attach to existing `:telemetry` events (Phoenix, Ecto, Oban).
- Add new spans (`:telemetry.span/3`) to critical gaps identified in static analysis (VSM message handlers, internal service bridges).

### Phase 2: Trace Collector
- Implement an ephemeral collector (GenServer + ETS) to buffer traces in memory.
- Group spans by `trace_id`.

### Phase 3: Traffic Generator & Report
- Create a Mix task `mix cyb.trace` that:
    1. Starts the application and tracer.
    2. Injects synthetic traffic (HTTP requests, AMQP messages).
    3. Waits for processing.
    4. Dumps captured traces to `dynamic-traces.json`.

## Output
Structured JSON compatible with the static analysis format for easy comparison.
