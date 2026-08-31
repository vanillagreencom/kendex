# Dev round schema

The on-disk record of a fix round's delegated items, starting commit, and allowed protected additions. The orchestrator writes it with `dev-round-write` immediately after minting the round token and before sending the delegation.

## Identity: the round id

The recovery copy is `[WORKTREE_PATH]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json`. The authorization is `<git-common-dir>/kendex/dev-round-authorizations/[ISSUE_ID]-[ROUND_ID].json`, outside the delegated worktree. Both carry `"round_id": ROUND_ID`; readers require both regular files and exact equality across issue, round id, base SHA, additions, and items. The external authorization alone carries Boolean `live`, initially `true`.

`[ISSUE_ID]` is the normalized workflow-state key — dev-side workflows name the same value `[ARTIFACT_KEY]`, and a bundled round uses the Parent ID. It and `[ROUND_ID]` must match `^[A-Za-z0-9._-]+$` with no `..`.

## Schema

```json
{
  "schema_version": 2,
  "round_id": "1769600000123456789-1837",
  "issue": "issue-1230",
  "base_sha": "0123456789abcdef0123456789abcdef01234567",
  "adds": ["tools/refresh-fixture"],
  "items": [
    { "n": 1, "text": "#1 | security-review | src/auth.rs\nDescription: \"token refresh races\"\nRecommendation: \"serialize refresh behind the existing lock\"" }
  ]
}
```

| Field | Required | Writer flag | Description |
|-------|----------|-------------|-------------|
| `schema_version` | Yes | constant `2` | Record schema version |
| `round_id` | Yes | `--round-id` | Per-delegation token; equals the filename token and the round's `dev_round_id` |
| `issue` | Yes | `--issue` | Normalized workflow-state key |
| `base_sha` | Yes | captured from `HEAD` | Commit at delegation time |
| `adds` | Yes | `--adds-file JSON_PATH` | Exact protected additions the round may make; an empty array allows none in the protected scope |
| `items` | Yes (>=1) | `--items-file` or `--item N TEXT` | `n` is the delegated item number (a unique integer >= 0), `text` the item's formatted block verbatim |

`--items-file` is the default route: build the array with the harness file-write tool. The inline `--item N TEXT` form is equivalent when every item's text is plain, with `N` a canonical integer. The two sources are mutually exclusive; `dev-round-write --help` is the flag reference.

An `Adds:` delegation line maps to a JSON array passed through `--adds-file`; repository paths never enter shell command text. The writer and reader reject absolute paths, leading or trailing empty components, double slashes, `.` and `..` components, newlines, carriage returns, and duplicates. Omit the line and flag when no additions are allowed.

The external authorization adds `"schema_version": 1`, `"worktree": "[CANONICAL_WORKTREE_ROOT]"`, and `"live": true` to the same issue, round, base, additions, and items fields.

**Immutable per round.** Delegation fields never change. Re-running before acceptance when both records have byte-identical content is an idempotent retry. Different delegated content, a missing half, or a symlink exits 2. Never recreate either half after delegation and never fall back to an unbound item list. Mint a new round. An analysis round has no delegated items and writes no record.

**Liveness.** On an `accept` verdict, `dev-artifact-check` atomically replaces the external authorization with the same record carrying `"live": false`. Repeat checks accept the retired record. `worktree-push` remaps only a live authorization, so a completed round cannot block a later rebase after its recovery copy is gone.

## Readers

- **`dev-artifact-check --expect-items-from-round`** derives the expected items and additions from the external authorization after checking the worktree copy exactly matches it. It compares the exact `base_sha` snapshot directly to `HEAD` through a checked, NUL-delimited Git probe, then retires an accepted authorization. `worktree-push` remaps both copies only while the authorization is live. Comparison failures return `comparison_failed`; an unusable classifier result returns `classifier_failed`.
- **A respawned dev agent** reads `items[]` to recover the item numbers and texts.
- **The tail-reconciliation nudge** points at the record.

The record is input, never receipt: it proves what was delegated, not that anything completed. Completion stays with [`dev-return.md`](dev-return.md) and the A/B acceptance tables.

## Protected additions

The gate checks additions only. Git rename detection keeps moves and renames outside it.

Protected additions are:

- root `crates/` and `tools/`;
- `skills/*/scripts/` and `.agents/skills/*/scripts/`;
- root or nested `src/test/`;
- directories named `helper`, `helpers`, `test-helper`, `test-helpers`, `test_helper`, `test_helpers`, `test-util`, `test-utils`, `test_util`, or `test_utils`;
- any later `helper`, `helpers`, `lib`, `support`, `util`, or `utils` directory component after a `test`, `tests`, or `__tests__` component, regardless of intervening suite directories;
- repository-relative paths containing `test-helper`, `test_helper`, `test-util`, or `test_util`;
- files below a `test/`, `tests/`, or `__tests__/` path component whose basename before the first extension contains lowercase `helper`, `test-util`, or `test_util`, including suffix forms and dotfiles.

`unapproved_additions` returns every refused protected path in `files`.
