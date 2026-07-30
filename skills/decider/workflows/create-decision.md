# Create Decision Workflow

Create a new decision entry: assign ID, write decision file, add INDEX.md row, update code references.

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| `decision_content` | Caller (agent reports, research findings) | Yes |
| `research_ref` | Caller (research docs path) | No |
| `research_issue_id` | Caller (issue that prompted research) | No |

`decision_content` must include at minimum: summary, rationale, and revisit conditions.

---

## 1. Assign Decision ID

### 1.1 Get Next ID

```bash
.agents/skills/decider/scripts/decisions next-id
```

**If `.agents/skills/decider/scripts/decisions` is unavailable**: Read `[project decision documents]/INDEX.md`, inspect only the ID column, infer the numeric-suffix scheme from the last populated ID, then increment the highest number with that same prefix. If no ID exists, use the project's documented default or `D001`.

### 1.2 Generate Descriptor

From decision summary, derive a 2-5 word kebab-case descriptor.

Examples:
- "Use Redis for session caching" → `session-caching`
- "Test file organization patterns" → `test-file-organization`
- "Auth/Cloud Storage Stack" → `auth-cloud-storage`

Store as `[DECISION_ID]` (e.g., `D034` or `ADR-0034`) and `[DESCRIPTOR]` (e.g., `auth-cloud-storage`).

---

## 2. Select Template

Based on scope of the decision, select the appropriate template from `templates/decision-entry.md`:

| Scope | Template | Signals |
|-------|----------|---------|
| Single technology choice, clear winner | Minimal | 1-2 rationale points, no alternatives table |
| Multiple alternatives, patterns to document | Standard | Comparison table, code examples, decision criteria |
| Architecture-level, multi-concern | Comprehensive | Requirements table, design sections, API specs, impact analysis |

---

## 3. Write Decision File

1. **Create file** at `[project decision documents]/[DECISION_ID]-[DESCRIPTOR].md`

2. **Fill template** with `decision_content`:

   **Required fields** (all templates):
   - `**Date**:` — today's date (`YYYY-MM-DD`)
   - `**Status**:` — `Active`
   - `**Research**:` — `[RESEARCH_REF]` link or `—`
   - Decision statement — what was chosen
   - Rationale — why, bullets preferred
   - Revisit When — conditions for re-evaluation

   **Keep tight** — reference research for details. Decision documents summarize; research documents contain the full analysis.

3. **Add cross-references** if decision relates to existing decisions:
   - Link to related decisions: `[DECISION_ID](DECISION_ID-descriptor.md)`
   - Note if decision refines prior work: `**Refines**: [DECISION_ID](DECISION_ID-descriptor.md)`

---

## 4. Add INDEX.md Row

1. **Read** `[project decision documents]/INDEX.md`

2. **Add row** at end of decision table (before `---` separator), per `templates/index-row.md`:

   ```markdown
   | [DATE] | [DECISION_ID] | [RESEARCH_REF] | [DECISION_SUMMARY] | [RATIONALE_SUMMARY] | [REVISIT_WHEN] | Active | [Full]([DECISION_ID]-[DESCRIPTOR].md) |
   ```

   Each field should be a tight 5-15 word summary.

---

## 5. Update Partially Superseded Decisions

**Skip if** no existing decisions are partially affected.

If the new decision's context references other active decisions as partially affected (e.g., "D011 specified ThreadBound..."):

1. **Read** referenced decision file
2. **If** new decision replaces specific components but not the whole:
   - Update status to `Active ([COMPONENTS] -> [DECISION_ID])` in both the decision file and INDEX.md row
3. **If** new decision fully replaces:
   - Update status to `Superseded by [DECISION_ID]` in both locations

---

## 6. Add Code References

**Skip if** decision doesn't affect existing code.

For implementation points tied to this decision:

```
// REVISIT([DECISION_ID]): [reason this code may need to change]
```

Every `REVISIT` comment must reference a decision ID from the INDEX.

---

## 7. Return

Return the created decision reference:

```
Decision: [DECISION_ID] - [TITLE]
Path: [project decision documents]/[DECISION_ID]-[DESCRIPTOR].md
```
