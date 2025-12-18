---
description: Synchronize status between Spec Kit tasks.md and Linear issues bidirectionally
tools: ['mcp__linear__search_issues', 'mcp__linear__update_issue', 'mcp__linear__get_user_issues']
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. **Validate prerequisites**:
   - Run `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks`
   - Parse FEATURE_DIR and verify tasks.md exists
   - Load `.specify/linear-mapping.json` for task-to-issue mapping

2. **Determine sync direction**:
   - `--to-linear`: Push tasks.md status → Linear (default)
   - `--from-linear`: Pull Linear status → tasks.md
   - `--bidirectional`: Merge both (Linear wins on conflicts)

3. **Fetch current state from both sources**:

   **From tasks.md**:
   - Parse each task's completion status `[x]` vs `[ ]`
   - Extract task IDs and descriptions

   **From Linear** (using mapped issue IDs):
   - Fetch each issue's current status
   - Map Linear status to completion:
     | Linear Status | tasks.md |
     |---------------|----------|
     | Done, Completed, Closed | `[x]` |
     | In Progress | `[ ]` (with note) |
     | Todo, Backlog | `[ ]` |
     | Canceled | `[-]` (skipped) |

4. **Detect changes and conflicts**:
   ```
   Sync Analysis:

   | Task | tasks.md | Linear | Action |
   |------|----------|--------|--------|
   | T001 | [x] | In Progress | → Update Linear to Done |
   | T002 | [ ] | Done | ← Update tasks.md to [x] |
   | T003 | [x] | Done | ✓ In sync |
   | T004 | [ ] | Todo | ✓ In sync |
   ```

5. **Apply changes based on direction**:

   **--to-linear (default)**:
   - For each task marked `[x]` in tasks.md:
     - Update Linear issue status to "Done"
   - For tasks marked `[ ]`:
     - If Linear shows "Done", warn about potential regression

   **--from-linear**:
   - For each Linear issue marked "Done":
     - Update tasks.md to `[x]`
   - For issues "In Progress":
     - Add comment to task: `<!-- In Progress in Linear -->`

   **--bidirectional**:
   - Linear status takes precedence on conflicts
   - Update both systems to match

6. **Update tracking metadata**:
   - Update `.specify/linear-mapping.json` with sync timestamp:
     ```json
     {
       "last_sync": "2025-01-15T14:30:00Z",
       "sync_direction": "bidirectional",
       "changes_applied": 3
     }
     ```

7. **Add sync comment to Linear parent issue**:
   ```
   🔄 Spec Kit Sync: 2025-01-15 14:30 UTC

   Progress: 8/12 tasks complete (67%)

   Recently completed:
   - T005: Add rate limiting middleware
   - T006: Implement session timeout

   Remaining:
   - T007: Add audit logging
   - T008: Performance optimization
   ```

8. **Output summary**:
   ```
   ✅ Sync complete

   Direction: tasks.md → Linear

   Changes:
   - Updated 2 Linear issues to Done
   - Detected 1 conflict (T002 marked done locally but In Progress in Linear)

   Current Progress: 8/12 tasks (67%)

   Conflicts (require manual resolution):
   - T002: Local=[x], Linear=In Progress
     → Run with --from-linear to accept Linear status
     → Or update Linear manually to Done
   ```

## Error Handling

- **No mapping file**: Suggest running `/speckit.linear.export` first
- **Linear issue deleted**: Mark as orphaned, suggest cleanup
- **Network error**: Retry with exponential backoff, report partial sync
- **Permission denied**: Verify API key permissions

## Options

- `--to-linear`: Push local status to Linear (default)
- `--from-linear`: Pull Linear status to local
- `--bidirectional`: Two-way sync (Linear wins conflicts)
- `--dry-run`: Show changes without applying
- `--force`: Override conflicts without prompting

## Notes

- Sync is idempotent - safe to run multiple times
- Canceled Linear issues are marked `[-]` in tasks.md (skipped)
- Progress percentage is reported to Linear for visibility
- Consider running sync before and after implementation sessions
