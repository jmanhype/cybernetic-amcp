# Implement Mock AMQP Publisher for Tracing

## Overview
Implement an in-memory Mock AMQP Publisher to allow full dynamic tracing without external RabbitMQ dependency. This resolves the crash encountered in Item 004 and enables capturing complete VSM feedback loops.

## Goals
1.  **Prevent Crashes**: Provide a valid process for `Cybernetic.Core.Transport.AMQP.Publisher` calls.
2.  **Enable Full Traces**: Allow messages to flow S1 -> S2 -> S3 -> S4 -> S5 without external infrastructure.
3.  **Capture Messaging Topology**: Record "publish" events as spans to visualize inter-system dependencies.

## Phases

### Phase 1: Create Mock Publisher
- Create `Cybernetic.Archeology.MockPublisher` GenServer.
- Implement `start_link/1` to register as `Cybernetic.Core.Transport.AMQP.Publisher`.
- Implement `handle_call({:publish, ...}, ...)` to accept messages.

### Phase 2: In-Memory Routing
- In `handle_call`, emit a `:telemetry` span for the publish event.
- Inspect the routing key (e.g., "s2.coordinate").
- **Crucial Step:** Immediately dispatch the message to the target system's MessageHandler (e.g., `Cybernetic.VSM.System2.MessageHandler.handle_message/3`).
- This converts async AMQP messaging into synchronous function calls for the purpose of the trace.

### Phase 3: Integrate with Trace Task
- Update `Mix.Tasks.Cyb.Trace` to start the MockPublisher before generating traffic.
- Ensure it only runs in test/dev mode (guard clauses).

## Output
A `dynamic-traces.json` file containing the full conversation history of the VSM systems.