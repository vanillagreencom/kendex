# Create Decision

Inputs: summary, reasons, and revisit conditions (required); research reference and prompting issue (optional).

## 1. Assign the ID and descriptor

```bash
.agents/skills/decider/scripts/decisions next-id
```

A `notice=base-unverified` line says the base was not fully read; its reason is listed under `DECISIONS_BASE_REF` in `decisions --help`.

Without the script:

1. Select the project's ID scheme from its configuration or last populated INDEX ID. If neither supplies one, ask for the scheme.
2. Inspect the working and base-branch indexes.
3. Increment the highest numeric suffix reserved in that scheme.
4. Disclose an unread base instead of claiming its IDs were checked.

Derive a 2-5 word kebab-case descriptor from the summary — "Use Redis for session caching" → `session-caching`.

## 2. Write the decision file

Create `[DECISIONS_DIR]/[DECISION_ID]-[DESCRIPTOR].md` from `templates/decision-entry.md`. Date it today. Write nothing longer than `schemas/decision-format.md` § Decision document allows.

Link related decisions as `[DECISION_ID](DECISION_ID-descriptor.md)`. Add `**Refines**:` when this extends prior work.

## 3. Add the INDEX row

Append a row per `templates/index-row.md` at the end of the table, before the `---` separator. Never re-sort, even for a decision written up late.

## 4. Restate partially superseded decisions

Skip when no existing decision is affected. Otherwise, for each active decision this one displaces, set the status in **both** the decision file and its INDEX row:

- `Active ([COMPONENTS] → [DECISION_ID])` when only named components are replaced.
- `Superseded by [DECISION_ID]` when the whole decision is.

## 5. Mark the code

Skip when no existing code is affected. At each implementation point that carries out this decision, and nowhere else:

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

Run this when `decisions check` or `decisions get` refuses an ID that two records share. The base keeps the number, and the branch's record takes a new one from `next-id`. Change every `DECISION_ID` occurrence `schemas/decision-format.md` defines for the branch's record, including:

- the file name, `[DECISION_ID]-[DESCRIPTOR].md`
- the `# [DECISION_ID]: Title` line
- the INDEX row's ID and Link cells
- the `[DECISION_ID](DECISION_ID-descriptor.md)` links other records carry
- the Status values that name it, `Superseded by [DECISION_ID]` and `Active ([COMPONENTS] → [DECISION_ID])`, in INDEX Status cells and `**Status**:` lines
- the `**Refines**:` lines that name it
- the `REVISIT([DECISION_ID])` markers in code
- the `**Decision [DECISION_ID]**:` reference in the prompting issue

The commit-guards `md-refs` lane catches missing link targets and, where decision checks apply, IDs without tracked records. It cannot decide whether a reference names the intended policy. Read the status cells, link labels and code markers of the renumbered record.
