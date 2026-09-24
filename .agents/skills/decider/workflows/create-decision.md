# Create Decision

Assign an ID, write the decision file, add its INDEX row, restate what it supersedes, and mark the code.

Inputs: summary, reasons, and revisit conditions (required); research reference and prompting issue (optional).

## 1. Assign the ID and descriptor

```bash
.agents/skills/decider/scripts/decisions next-id
```

`next-id` also reads the base branch's INDEX, so it skips a number another branch already merged. A `notice=base-unverified` line means the base was not read or not fetched, and the number is checked against this branch alone.

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

## Renumber a record

`decisions check` refuses an ID the base branch records for another decision, and `check` or `get` refuses an ID two rows or two documents share. The base keeps the number, and the branch's record takes a new one from `next-id`. Change every place the old ID appears on the branch's record, per `schemas/decision-format.md`:

- the file name, `[DECISION_ID]-[DESCRIPTOR].md`
- the `# [DECISION_ID]: Title` line
- the INDEX row's ID and Link cells
- the `[DECISION_ID](DECISION_ID-descriptor.md)` links other records carry
- the `REVISIT([DECISION_ID])` markers in code
- the `**Decision [DECISION_ID]**:` reference in the prompting issue

Check the citations by reading them: the commit-guards `md-refs` lane passes a citation left at the old number, because that number still names the base's record.
