---
description: Import a Linear issue into Spec Kit as a new feature specification
tools: ['mcp__linear__search_issues', 'mcp__linear__get_user_issues']
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. **Parse the Linear issue reference** from user input:
   - Accept formats: `LINEAR-123`, `TEAM-123`, `https://linear.app/team/issue/TEAM-123`, or issue title search
   - If no input provided, ask: "Which Linear issue should I import? (e.g., TEAM-123 or search term)"

2. **Fetch the issue from Linear** using MCP:
   - Use `mcp__linear__search_issues` with the issue identifier or search query
   - Extract: title, description, priority, labels, assignee, status, comments
   - If multiple results, show list and ask user to select

3. **Determine feature number**:
   - Check existing `specs/` directory for highest numbered feature
   - Increment to get next feature number (e.g., `002` if `001` exists)

4. **Create feature directory**:
   ```bash
   mkdir -p specs/[NUMBER]-[SLUG]/
   ```
   - Generate slug from issue title (lowercase, hyphens, max 50 chars)
   - Example: `specs/002-user-authentication/`

5. **Generate spec.md from Linear issue**:
   - Use the spec template from `.specify/templates/spec-template.md`
   - Map Linear fields to spec sections:

   | Linear Field | Spec Section |
   |--------------|--------------|
   | Title | Feature title |
   | Description | Overview / User Stories |
   | Priority | Priority (P1/P2/P3) |
   | Labels | Tags/Categories |
   | Comments | Additional context in Notes |

6. **Add Linear tracking metadata** to spec header:
   ```markdown
   ---
   linear_id: TEAM-123
   linear_url: https://linear.app/team/issue/TEAM-123
   imported_at: 2025-01-15T10:30:00Z
   sync_status: imported
   ---
   ```

7. **Create bidirectional link**:
   - Add comment to Linear issue (using `mcp__linear__add_comment`):
     ```
     📋 Spec Kit: Feature specification created
     Path: specs/[NUMBER]-[SLUG]/spec.md
     ```

8. **Output summary**:
   ```
   ✅ Imported LINEAR-123 → specs/002-user-authentication/

   Linear Issue: [Title]
   Spec Path: specs/002-user-authentication/spec.md
   Priority: P1

   Next steps:
   - Run /speckit.clarify to resolve any ambiguities
   - Run /speckit.plan when ready for technical planning
   ```

## Error Handling

- **Linear MCP not configured**: Display setup instructions pointing to `.mcp.json.linear-example`
- **Issue not found**: Suggest checking issue ID or using search
- **Permission denied**: Verify API key has read access to the team
- **Multiple matches**: Show numbered list for user selection

## Notes

- This command requires the Linear MCP server to be configured
- The spec will be technology-agnostic (Linear technical details go in plan.md later)
- Original Linear issue remains the source of truth for project management
- Use `/speckit.linear.sync` to keep status synchronized
