# Create Decision

Assign an ID, write the decision file, add its INDEX row, restate what it supersedes, and mark the code.

Inputs: summary, reasons, and revisit conditions (required); research reference and prompting issue (optional).

## 1. Assign the ID and descriptor

```bash
.agents/skills/decider/scripts/decisions next-id
```

Without the script: take the last populated INDEX ID value and increment its numeric suffix. If it has none, ask for the project's scheme.

Derive a 2-5 word kebab-case descriptor from the summary — "Use Redis for session caching" → `session-caching`.

## 2. Write the decision file

Create `[DECISIONS_DIR]/[DECISION_ID]-[DESCRIPTOR].md` from `templates/decision-entry.md`, sized to scope. Required: today's date, `**Status**: Active`, the research ref or `—`, what was chosen, why, and the revisit conditions. Keep it tight.

Link related decisions as `[DECISION_ID](DECISION_ID-descriptor.md)`, and add `**Refines**:` when this extends prior work.

## 3. Add the INDEX row

Append a row per `templates/index-row.md` at the end of the table, before the `---` separator. Cells are 5-15 word summaries; the Link cell names the file just written.

## 4. Restate partially superseded decisions

Skip when no existing decision is affected. Otherwise, for each active decision this one displaces, set the status in **both** the decision file and its INDEX row: `Active ([COMPONENTS] → [DECISION_ID])` when only named components are replaced, `Superseded by [DECISION_ID]` when the whole decision is.

## 5. Mark the code

Skip when no existing code is affected. At each implementation point tied to this decision:

```
// REVISIT([DECISION_ID]): [what would change]
```

Every `REVISIT` marker names an ID present in the INDEX.

## 6. Return

```
Decision: [DECISION_ID] - [TITLE]
Path: [DECISIONS_DIR]/[DECISION_ID]-[DESCRIPTOR].md
```
