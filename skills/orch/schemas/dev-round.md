# Dev Round (Delegated Item Set) Schema

The durable on-disk record of a fix round's **delegated item set**, written by
the **orchestrator** when the round is stamped — the input-side twin of the
dev-return completion artifact (vstack#1230). Before it existed, the delegated
set (a curated, renumbered subset of the raw review findings) lived only in the
delegation message: a dev agent respawned mid-round could not write a truthful
completion artifact, the `ok==false` tail-reconciliation nudge assumed the
agent still knew its items, and `dev-artifact-check --expect-items` took a
number list typed from the orchestrator's context rather than an on-disk
source of truth.

## Deterministic identity: the round id (vstack#776)

The record follows the same round-token discipline as the completion artifact:

- its filename is `[WORKTREE_PATH]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json`, and
- it carries `"round_id": ROUND_ID` inside.

`[ISSUE_ID]` is the normalized workflow-state key — dev-side workflows name this same value `[ARTIFACT_KEY]`, and for a bundled round it is the Parent ID (`issue-N` for GitHub,
`PROJ-123` for Linear); it and `[ROUND_ID]` must match the path-safe grammar
`^[A-Za-z0-9._-]+$` with no `..`. Readers reject a record whose internal token
differs from the expected round id, so a copied or renamed file from another
round can never stand in for this round's record.

## Written by `dev-round-write` — orchestrator-side, at stamp time

The orchestrator runs the writer immediately after minting the round token
(`workflow-state new-round-id [ISSUE_ID] dev_round_id`), before sending the
delegation (`dev-fix.md` § 2 step 5, `review-pr-comments.md` § 6.1 step 3):

```bash
.agents/skills/orch/scripts/dev-round-write --worktree [WORKTREE_PATH] --issue [ISSUE_ID] \
  --round-id [DEV_ROUND_ID] --items-file [ITEMS_JSON_PATH]
```

`[ITEMS_JSON_PATH]` is a JSON file the orchestrator builds with its harness
file-write tool (per SKILL § Harness-Safe Shell — file bodies go through
harness file tools, and a literal backtick in a command is rejected by strict
classifiers even quoted): a non-empty array of `{"n": …, "text": "…"}`, one per
delegated review item. `n` is the item's delegated number (an integer >= 0,
unique — the numbers form a set), `text` the item's full formatted block
verbatim. Extra element keys are dropped on normalization. When every item's
text is plain (no backticks, quotes, or `$`), the inline form is equivalent:

```bash
.agents/skills/orch/scripts/dev-round-write --worktree [WORKTREE_PATH] --issue [ISSUE_ID] \
  --round-id [DEV_ROUND_ID] --item [N] '[ITEM_TEXT]' [--item [N] '[ITEM_TEXT]']...
```

Inline `[N]` must be a canonical integer (no leading zeros — `01` is not a
JSON number). The two item sources are mutually exclusive. Either form is a
sanctioned single-command invocation (harness-safe, atomic temp-file + `mv`
write) and prints the record's absolute path; all usage/validation errors
exit 2.

**Immutable per round** (vstack#1230): re-running with byte-identical content
is an idempotent retry (success, same path); different content under the same
round id exits 2 — a retry with a partial list must never silently shrink the
authoritative delegated set. A changed delegation mints a NEW round id
(`workflow-state new-round-id`), the same one-token-one-delegation discipline
the completion artifact follows. Analysis (read-only) rounds have no delegated
items and write NO record — the writer rejects an empty set by design.

## Schema

```json
{
  "schema_version": 1,
  "round_id": "1769600000123456789-1837",
  "issue": "issue-1230",
  "items": [
    { "n": 1, "text": "#1 | security-review | src/auth.rs\nDescription: \"token refresh races\"\nRecommendation: \"serialize refresh behind the existing lock\"" }
  ]
}
```

## Fields

| Field | Required | Writer flag | Description |
|-------|----------|-------------|-------------|
| `schema_version` | Yes | (constant `1`) | Record schema version (number) |
| `round_id` | Yes | `--round-id` | Per-delegation token; must equal the filename token and the round's `dev_round_id` |
| `issue` | Yes | `--issue` | Normalized workflow-state key; grammar `^[A-Za-z0-9._-]+$`, no `..` |
| `items` | Yes (>=1) | `--item N TEXT` / `--items-file` | The delegated item set: `n` is the delegated item number (integer >= 0, unique), `text` the item's formatted block verbatim (non-empty) |

## Readers

- **`dev-artifact-check --expect-items-from-round`** (round mode only) derives
  the exact expected item-number set from `items[].n` instead of a typed
  `--expect-items` list. It validates the FULL record schema — parseable JSON,
  internal `round_id` equal to the expected token, `issue` equal to `--issue`,
  `schema_version` a number, non-empty `items[]` of unique integer `n` with
  non-empty `text` — and refuses to run (exit 2) on a missing or unusable
  record: never a silent downgrade to the weaker fix/bundled fallback gate.
  The count-vs-set `hint` diagnoses a typed `--expect-items` count only and is
  never emitted for a from-round set.
- **A respawned dev agent** (`dev/workflows/dev-fix.md` § 6) reads `items[]`
  to recover exactly what was delegated — item numbers and texts — instead of
  guessing a mapping from the raw review JSONs, which would put fabricated
  reasoning into the durable completion record.
- **The `ok==false` tail-reconciliation nudge** (`dev-fix.md` § 2 step 6,
  `review-pr-comments.md` § 6.1) points at the record, so the nudge is
  self-sufficient even after the agent (or the whole session) was lost and
  respawned mid-round.

The record is input, not receipt: it proves what was delegated, never that
anything completed. Completion stays with the dev-return artifact
([`dev-return.md`](dev-return.md)) and the A/B acceptance tables.
