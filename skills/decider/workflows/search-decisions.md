# Search Decisions Workflow

Search and retrieve decision documents by issue reference, keywords, or ID.

## Commands

| Command | Purpose | Output |
|---------|---------|--------|
| `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]` | Find decisions linked to an issue | JSON `[{id, decision, path}]` |
| `.agents/skills/decider/scripts/decisions search "[KEYWORDS]"` | Ranked keyword search (AND, scored) | JSON `[{id, decision, path, score}]` |
| `.agents/skills/decider/scripts/decisions search "term1\|term2"` | Regex OR search | JSON `[{id, decision, path}]` |
| `.agents/skills/decider/scripts/decisions list` | List all active decisions | JSON `[{id, decision, path}]` |
| `.agents/skills/decider/scripts/decisions next-id` | Get next available DXXX | Single line `DXXX` |
| `.agents/skills/decider/scripts/decisions get [DECISION_ID]` | Get decision details | JSON `{id, decision, status, date, path}` |

Options: `--limit N` (default: 5) for search results.

---

## 1. Search by Issue

```bash
.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
```

Searches INDEX.md Research column for exact issue reference match (with negative lookahead to prevent partial matches like PROJ-18 matching PROJ-189).

**Output**: JSON array of matching decisions.

```json
[{"id":"D017","decision":"Storage Trait Design","path":"docs/decisions/D017-storage-trait-design.md"}]
```

**If no matches**: Empty array `[]`. The same empty array (exit 0, with a stderr note) is returned when the project has no decisions directory yet — treat it as "no decisions recorded", not a failure.

---

## 2. Search by Keywords

```bash
.agents/skills/decider/scripts/decisions search "[KEYWORDS]"
```

Multi-word AND search with relevance scoring:
- Decision/title match: 3 points per term
- ID match: 3 points per term
- Rationale match: 1 point per term
- All terms must match (AND logic)

Contains `|`, `()`, or `\` → regex mode (no scoring, direct pattern match).

**Output**: JSON array sorted by score descending, limited to `--limit N`.

```json
[{"id":"D001","decision":"Use Redis for session caching","path":"docs/decisions/D001-session-caching.md","score":7}]
```

---

## 3. List Active

```bash
.agents/skills/decider/scripts/decisions list
```

Returns all decisions with status starting with `Active` (includes partially superseded entries like `Active (X → DXXX)`).

---

## 4. Get Next ID

```bash
.agents/skills/decider/scripts/decisions next-id
```

Reads INDEX.md, finds the highest DXXX number, returns `D{N+1}` (zero-padded).

**Output**: `D034`

---

## 5. Get Decision

```bash
.agents/skills/decider/scripts/decisions get [DECISION_ID]
```

**Output**: JSON with enriched details.

```json
{"id":"D017","decision":"Storage Trait Design","path":"docs/decisions/D017-storage-trait-design.md","status":"Active","date":"2026-02-17"}
```

---

## Usage in Workflows

### Before implementing (feasibility check)

```bash
.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"
```

Find governing decisions. If matches found, **read the full decision file** — index summaries are insufficient for understanding scope and rejected alternatives.

### Before applying review fixes

```bash
.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"
```

If review item contradicts an active decision, skip with decision reference (e.g., "Skipped — contradicts D010").

### During PR review context gathering

```bash
.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
```

Collect decision IDs and summaries for inclusion in delegation prompts. Agents must read cited decisions before suggesting changes.

### During PR body construction

```bash
.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
```

Include matching decisions in PR Context section:
```markdown
- **[DECISION_ID]**: [ONE_LINE_SUMMARY] — `[DECISION_FILE_PATH]`
```

### Contradict-check for suggestions

Suggestions that contradict active decisions are invalid unless the decision itself is flawed (flag as blocker with justification, citing the specific decision and why it's wrong).
