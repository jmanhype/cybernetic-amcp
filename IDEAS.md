System archeology for Cybernetic AMCP. No opinions, only traces.

PHASE 1 - Entry points:
List every external entry point (HTTP, MQ, CLI, cron).
Format: [type] | [file:line] | [function]

PHASE 2 - Traces (one per entry point):
For each entry point, trace to exit.
Format: file:line → file:line → file:line

PHASE 3 - Shared modules:
Which modules appear in 2+ traces?

PHASE 4 - Orphans:
Public functions that appear in zero traces.

Output as structured data. No prose.