---
description: "Quick fix command for simple changes that don't require full workflow. Usage: /speckit.fix <description of fix>"
---

# Quick Fix Command

## User Input

```text
$ARGUMENTS
```

## Purpose

This command is for **simple, targeted fixes** that don't warrant the full specify → plan → tasks → implement workflow.

**Use this for:**
- Typo fixes
- Color/style changes
- Simple bug fixes with obvious solutions
- Adding missing imports
- Fixing linting errors
- Small refactors (rename variable, extract function)
- Documentation typos
- Configuration tweaks

**Do NOT use this for:**
- New features (use `/speckit.specify`)
- Architectural changes (use full workflow)
- Security fixes (need proper review)
- Changes affecting multiple systems
- Anything requiring design decisions

## Workflow

1. **Parse the fix request** from `$ARGUMENTS`

2. **Validate scope** - If the fix seems complex, recommend full workflow:
   ```
   This fix appears to require architectural decisions.
   Consider using /speckit.specify instead.
   ```

3. **Locate the issue**:
   - Search codebase for relevant files
   - Identify the specific location(s) to change

4. **Apply the fix**:
   - Make the minimal change required
   - Follow project-standards skill (invoke if needed for guidance)
   - Ensure tests still pass (test-gate.sh will run automatically)

5. **Verify**:
   - Confirm the fix addresses the issue
   - Check no regressions introduced

6. **Report**:
   ```markdown
   ## Fix Applied

   **Issue**: [Brief description]
   **Files Changed**:
   - `path/to/file.ext` (line X)

   **Change Summary**: [What was changed]

   **Tests**: ✓ Passing
   ```

## Beads Integration (Optional)

If this fix relates to an existing Beads issue:

```bash
# Link to existing issue
bd note <issue-id> "Quick fix applied: $ARGUMENTS"

# Or create a new issue if worth tracking
bd create "Fix: $ARGUMENTS" --type bug --status done
```

## Examples

### Example 1: Typo Fix
```
/speckit.fix Fix typo in README: "recieve" should be "receive"
```

### Example 2: Style Change
```
/speckit.fix Change primary button color from blue to green
```

### Example 3: Simple Bug
```
/speckit.fix Fix off-by-one error in pagination - showing 9 items instead of 10
```

### Example 4: Missing Import
```
/speckit.fix Add missing React import in UserProfile component
```

## Guardrails

- **Test gate still applies**: All tests must pass after the fix
- **Constitution compliance**: Follow project standards even for quick fixes
- **No scope creep**: If you discover larger issues, log them in Beads and address separately
- **Commit separately**: Quick fixes get their own commits with clear messages

## Escalation

If during the fix you discover:
- Security vulnerabilities → Stop, create Beads issue, notify user
- Architectural problems → Recommend `/speckit.specify` for proper planning
- Multiple related issues → Create Beads issues, recommend batched fix

```markdown
⚠️ This fix revealed a larger issue:
[Description of larger issue]

Recommendation: Create a proper feature spec with /speckit.specify
```
