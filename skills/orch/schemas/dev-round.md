# Dev Round (Delegated Item Set) Schema

The on-disk record of a fix round's **delegated item set** — the input-side twin of the dev-return completion artifact. The orchestrator writes it with `dev-round-write` immediately after minting the round token and before sending the delegation.

## Identity: the round id

Filename: `[WORKTREE_PATH]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json`, carrying `"round_id": ROUND_ID` inside. Readers reject a record whose internal token differs from the expected round id.

`[ISSUE_ID]` is the normalized workflow-state key — dev-side workflows name the same value `[ARTIFACT_KEY]`, and a bundled round uses the Parent ID. It and `[ROUND_ID]` must match `^[A-Za-z0-9._-]+$` with no `..`.

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

| Field | Required | Writer flag | Description |
|-------|----------|-------------|-------------|
| `schema_version` | Yes | (constant `1`) | Record schema version (number) |
| `round_id` | Yes | `--round-id` | Per-delegation token; equals the filename token and the round's `dev_round_id` |
| `issue` | Yes | `--issue` | Normalized workflow-state key |
| `items` | Yes (>=1) | `--items-file` or `--item N TEXT` | `n` is the delegated item number (a unique integer >= 0), `text` the item's formatted block verbatim |

`--items-file` is the default route: build the array with the harness file-write tool (a literal backtick in a command is rejected by strict classifiers even quoted). The inline `--item N TEXT` form is equivalent when every item's text is plain, with `N` a canonical integer (no leading zeros — `01` is not a JSON number). The two sources are mutually exclusive; `dev-round-write --help` is the flag reference.

**Immutable per round.** Re-running with byte-identical content is an idempotent retry; different content under the same round id exits 2. A changed delegation mints a new round id. An analysis round has no delegated items and writes no record — the writer rejects an empty set.

## Readers

- **`dev-artifact-check --expect-items-from-round`** derives the exact expected item-number set from `items[].n`, validating the record's full schema first and refusing to run on a missing or unusable one rather than downgrading to the fallback gate.
- **A respawned dev agent** reads `items[]` to recover the item numbers and texts.
- **The tail-reconciliation nudge** points at the record.

The record is input, never receipt: it proves what was delegated, not that anything completed. Completion stays with [`dev-return.md`](dev-return.md) and the A/B acceptance tables.
