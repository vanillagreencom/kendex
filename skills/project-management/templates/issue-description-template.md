# Issue Description Template

Standard format for issue tracker descriptions created by workflows. Match the structured style of existing well-authored issues.

## Template

```markdown
**Research**: [RESEARCH_REF]
**Decision [DXXX]**: [DECISION_PATH]
**Source**: [ORIGIN_CONTEXT]

[DESCRIPTION — 1-3 sentences explaining the problem or improvement]

## Requirements

* [REQUIREMENT_1]
* [REQUIREMENT_2]
* [REQUIREMENT_3]

## Context

- **Location**: `[FILE_PATH]`
```

## Field Mapping

| Placeholder | Source (audit input) | Notes |
|-------------|---------------------|-------|
| `[ORIGIN_CONTEXT]` | `"PR review suggestion ([found_by])"` or `"architecture planning"` etc. | Always include provenance |
| `[DESCRIPTION]` | `items[].description` | Use directly — agents write 2-3 sentences |
| `[REQUIREMENT_*]` | `items[].recommendation` | Use directly — agents write `* bullet` list |
| `[FILE_PATH]` | `items[].location` | Backtick-wrapped file path. **Never include line numbers** — they go stale as code changes. Use function/struct names for precision. |
| `[RESEARCH_REF]` | input `research_ref`, or inherit from parent description | Top of description. Omit if none |
| `[DXXX]` | input `decision_ref`, or inherit from parent description | After Research line. Omit if none |
| `[DECISION_PATH]` | Path to decision document in project decision documents | Full path to decision file |

## Rules

1. **Always use `--description-file`** for multiline descriptions — write the description to a file with the harness file-write tool, then pass its path. Never inline single-line strings, and never use a heredoc/command-substitution (`--description "$(cat <<'EOF' … )"`): under `never` approval those shell shapes are treated as approval-required and callers can't set a substantial description safely.
2. **Use fields directly** — review agents write issue-quality `description` and `recommendation`; no expansion needed at assembly time
3. **Omit empty lines** — drop Research, Decision, Context lines with no data
4. **Write actual newlines in the file** — JSON `\n` sequences become real newlines when the agent writes the description file
5. **Check decisions before creating** — `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"` to check if the proposed approach is governed by an active decision. Description must not contradict it. Reference the decision at the top of the description

## CLI Usage

Write the description body to a file (e.g. `tmp/issue-description.md`) with the harness file-write tool, then pass its path:

```bash
.agents/skills/linear/scripts/linear.sh issues create \
  --title "[TITLE]" \
  --project "[PROJECT]" \
  --labels "[LABELS]" \
  --priority [PRIORITY] \
  --estimate [ESTIMATE] \
  --parent [PARENT_ID] \
  --description-file tmp/issue-description.md
```

Where `tmp/issue-description.md` contains, for example:

```markdown
**Source**: PR review suggestion (e.g., test-review)

Connection pool capacity growth path is untested. A burst of concurrent
requests exceeding the initial pool size would trigger reallocation,
and the cap at max_connections*4 is untested.

## Requirements

* Create unit test with mock server returning near-capacity connections
* Verify pool grows correctly and caps at configured maximum
* Exercise concurrent request bursts

## Context

- **Location**: `src/pool/connection_pool.rs` (`ConnectionPool::grow`)
```

`--description-file` and `--description` are mutually exclusive. The same flag works on `issues update` for editing an existing description.
