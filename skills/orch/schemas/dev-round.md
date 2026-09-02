# Dev round schema

The on-disk record of a fix round's delegated items, starting commit, and allowed protected additions. The orchestrator writes it with `dev-round-write` immediately after minting the round token and before sending the delegation.

Before writing the record, `dev-round-write` compares the branch with workflow state `pr.baseline_lines`; a null or invalid value refuses without writing it. A branch above twice the recorded line count exits 3 and must be cut before another fix round can start.

## Identity: the round id

The record is `[WORKTREE_PATH]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` and carries `"round_id": ROUND_ID`; readers require a regular file — never a symlink — whose internal token, issue, and schema match what they were called with.

The record sits inside the delegated worktree, so it is trusted the way every other instruction to that agent is: the orchestrator writes it before delegating, and the delegated agent is trusted not to edit it. Immutability is enforced against a second `dev-round-write` invocation, not against the agent holding the worktree.

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
    { "n": 1, "text": "#1 | security-review | src/auth.rs\nDescription: \"token refresh races\"\nRecommendation: \"serialize refresh behind the existing lock\"", "reach": "a concurrent refresh from two open sessions on one account" }
  ]
}
```

| Field | Required | Writer flag | Description |
|-------|----------|-------------|-------------|
| `schema_version` | Yes | constant `2` | Record schema version |
| `round_id` | Yes | `--round-id` | Per-delegation token; equals the filename token and the round's `dev_round_id` |
| `issue` | Yes | `--issue` | Normalized workflow-state key |
| `base_sha` | Yes | captured from `HEAD` | Commit at delegation time; exactly 40 lowercase hex with nothing before or after, and readers refuse anything else — it reaches `git diff` as a revision argument |
| `adds` | Yes | `--adds "PATH [PATH...]"` | Exact protected additions the round may make; an empty array allows none in the protected scope |
| `items` | Yes (>=1) | `--items-file` or `--item N TEXT REACH` | `n` is the delegated item number (a unique integer >= 0), `text` the item's formatted block verbatim, `reach` the shipped producer, user action, or fixture that reaches the finding |

`--items-file` is the default route: build the array with the harness file-write tool. The inline `--item N TEXT REACH` form is equivalent when every item's text is plain, with `N` a canonical integer. The two sources are mutually exclusive; `dev-round-write --help` is the flag reference.

**`reach` is required per item, on both routes.** It names what reaches the finding: a command a person runs, a file a shipped writer emits, a test in the tree. An item with no reach is a `Declined:` reply, not a fix.

What the writer itself refuses is a short list, not a scanner: an empty or whitespace-only reach, a `PRRT_` review-thread node id anywhere in the value, and a few literal values. A value outside those shapes is recorded, not approved. The classes [`../references/finding-disposition.md` § Decision flow](../references/finding-disposition.md#decision-flow) excludes at Step 0 are the orchestrator's judgement at disposition time, before any round is delegated; `skills/orch/tests/dev_round_write.sh` pins the writer's verdict.

The `Adds:` delegation line and `--adds` carry the same blank-separated path list. A blank or tab separates, so a path containing whitespace is read as two paths and cannot be authorized as one. The writer rejects absolute paths, leading or trailing empty components, double slashes, `.` and `..` components, and duplicates. The reader refuses a recorded path beginning with `-` or carrying a space, tab, newline, carriage return, form feed or vertical tab. Omit the line and flag when no additions are allowed.

**Immutable per round**: `dev-round-write --help` carries the contract. Mint a new round and never fall back to an unbound item list. An analysis round has no delegated items and writes no record. While the ACTIVE round's record — the one whose token equals workflow state `dev_round_id` — has no matching `dev-return` receipt, `worktree-push` refuses to push: a rebase would move the branch off the base that record pins. Two things end that: the receipt landing, or a fresh `dev_round_id` whose token names no stamped record.

## Readers

- **`dev-artifact-check --expect-items-from-round`** derives the expected items and additions from the record; its gates and refusal reasons are that script's `--help`.
- **A respawned dev agent** reads `items[]` to recover the item numbers, texts, and reaches.
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
