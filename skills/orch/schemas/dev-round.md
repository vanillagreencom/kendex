# Dev round schema

The on-disk record of a fix round's delegated items, starting commit, and allowed protected additions. The orchestrator writes it with `dev-round-write` immediately after minting the round token and before sending the delegation.

For a chosen cut, see [§ Declared cuts](#declared-cuts).

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
  "delegated_at": 1769600000,
  "adds": ["tools/refresh-fixture"],
  "cut": false,
  "source": "pr-comments",
  "pr_open": true,
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
| `delegated_at` | Yes | captured from the clock | Epoch second the round's first `dev-round-write` invocation started. An identical retry keeps it: identity compares every other field |
| `adds` | Yes | `--adds "PATH [PATH...]"` | Exact protected additions the round may make; an empty array allows none in the protected scope |
| `cut` | Yes | `--cut` | Whether the round was declared a branch cut. Readers treat a missing or `null` `cut` as `false`, and refuse any other non-boolean value |
| `source` | Yes | `--source NAME` | The delegation's `Source:` value; null when the flag is absent |
| `pr_open` | Yes for new records | `--pr-open true\|false` | Whether the pull request was open at delegation. Defaults to `false`; readers treat an absent field as `false` and refuse a non-boolean value. A fix round requests `ci` only when this is `true`, regardless of `source`; otherwise it requests `range`. The runner may fall back to local validation. `dev-artifact-check` accepts a `ci` receipt only when this is `true` |
| `items` | Yes (>=1) | `--items-file` or `--item N TEXT REACH` | `n` is the delegated item number (a unique integer >= 0), `text` the item's formatted block verbatim, `reach` the shipped producer, user action, or fixture that reaches the finding; optional `recurrence` is one non-blank line preserved from `--items-file` |

`--items-file` is the default route: build the array with the harness file-write tool. The inline `--item N TEXT REACH` form is equivalent when every item's text is plain, with `N` a canonical integer. The two sources are mutually exclusive; `dev-round-write --help` is the flag reference.

## Item text

Stored `text` starts with `#[N] | [AGENT] | [LOCATION]` on its first line. Copy the header and that item's fields verbatim. Exclude outer `---` separators, leading blank lines, code fences and delegation headings from stored text. This contract applies to both `--items-file` and inline `--item` text.

**`reach` is required per item, on both routes.** It names what reaches the finding: a command a person runs, a file a shipped writer emits, a test in the tree. An item with no reach is a `Declined:` reply, not a fix.

The item's location is the text after the second `|` on the first line of `text`. Before writing a non-cut round, the writer reads the issue's `pr_comment_review.patched_causes` once through `workflow-state get`. Location strings match after blanks at both ends are removed. Case, path and symbol remain unchanged. Empty, `TBD` and `general` locations match nothing; an older entry with no `location` stays valid and matches nothing. A match requires `recurrence`, whose meaning [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence) owns. The inline form has no such field. An unanswered match exits 2 with `dev-round-write: repeat-location n=[N] location=[LOCATION] commit=[SHA]` first on stderr and writes no record. Unreadable state exits 2 with `dev-round-write: patched-state issue=[ID]` first on stderr. A refused stamp can take a corrected items file under the same round id. `--cut` skips the comparison.

An item that prescribes a mechanism tells the delegate to measure it first and report a mismatch instead of complying.

What the writer itself refuses is a short list, not a scanner: an empty or whitespace-only reach, a `PRRT_` review-thread node id anywhere in the value, and a few literal values. A value outside those shapes is recorded, not approved. The classes [`../references/finding-disposition.md` § Decision flow](../references/finding-disposition.md#decision-flow) excludes at Step 0 are the orchestrator's judgement at disposition time, before any round is delegated; [`tests/dev_round_write.sh`](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/tests/dev_round_write.sh) pins the writer's verdict.

The `Adds:` delegation line and `--adds` carry the same blank-separated path list. A blank or tab separates, so a path containing whitespace is read as two paths and cannot be authorized as one. The writer rejects absolute paths, leading or trailing empty components, double slashes, `.` and `..` components, and duplicates. The reader refuses a recorded path beginning with `-` or carrying a space, tab, newline, carriage return, form feed or vertical tab. Omit the line and flag when no additions are allowed.

**Immutable per round**: `dev-round-write --help` carries the contract. Mint a new round and never fall back to an unbound item list. While the ACTIVE round's record — the one whose token equals workflow state `dev_round_id` — has no matching `dev-return` receipt, `worktree-push` refuses to push and `worktree-push --check-live-round` refuses the restack: a rebase moves the branch off the commit that round is working from. Two things end that: the receipt landing, or a fresh `dev_round_id` whose token names no stamped record.

## Declared cuts

A reviewer or the orchestrator chooses a cut to bring the branch back to the Done-when. `dev-artifact-check --expect-items-from-round` checks its receipt against the round record.

A cut round's items name work rather than a finding, so the `reach` row's definition reads differently for them: a cut item's reach is the branch this round shrinks. It is still required, and still refused when it is empty or one of the writer's listed shapes — `the finding` among them.

`--cut` records `"cut": true`. The reviewer or orchestrator decides which work to cut. Acceptance checks the item set, reach, protected additions and immutability. A fresh retry repeats `--cut` and delegates the remaining work. Branch line counts do not decide acceptance.

## Readers

- **`dev-artifact-check --expect-items-from-round`** derives the expected items and additions from the record; its gates and refusal reasons are that script's `--help`.
- **`dev-return-write --kind fix`** reads `base_sha` and `delegated_at`, and names a validation run only when it started at a HEAD that contains that base, or records that base as the one a rebase left off the branch, no earlier than that time.
- **A respawned dev agent** reads `items[]` to recover the item numbers, texts, and reaches.
- **The tail-reconciliation nudge** points at the record.

The record is input, never receipt: it proves what was delegated, not that anything completed. Completion stays with [`dev-return.md`](dev-return.md) and the A/B acceptance tables.

## Protected additions

The gate checks additions only. Git rename detection keeps moves and renames outside it.

`base_sha` is the reference, and the only one: a file already in that tree is not this round's, which is what keeps a later round from re-refusing an addition an earlier one authorized. A rebase orphans it, and the orphaned tree reads every file the base branch advanced by as an addition this round made. Once `base_sha` is no longer an ancestor of `HEAD` the gate cannot run at all, and `dev-artifact-check` refuses the round with `reason: "additions_unattributable"` and an empty `files`: it names no path, because after a rebase no comparison can say which additions were this round's. The refusal is not a deferral. `dev-round-write` stamps the next round's `base_sha` at the worktree's current `HEAD`, so a round stamped after the rebase starts from a tree that already contains whatever this round added, and no later round can gate it. What the additions were is settled by reading that round's own commits against the scope below, and recorded where every other authorization is: the orchestrator mints a fresh round, names each deliberate path in its `Adds:` line, and cuts the rest before delegating it. Here that line is the authorization rather than something the fresh round's gate re-derives, because its base already carries those paths.

Protected additions are:

- root `crates/` and `tools/`;
- `skills/*/scripts/` and `.agents/skills/*/scripts/`;
- root or nested `src/test/`;
- directories named `helper`, `helpers`, `test-helper`, `test-helpers`, `test_helper`, `test_helpers`, `test-util`, `test-utils`, `test_util`, or `test_utils`;
- any later `helper`, `helpers`, `lib`, `support`, `util`, or `utils` directory component after a `test`, `tests`, or `__tests__` component, regardless of intervening suite directories;
- repository-relative paths containing `test-helper`, `test_helper`, `test-util`, or `test_util`;
- files below a `test/`, `tests/`, or `__tests__/` path component whose basename before the first extension contains lowercase `helper`, `test-util`, or `test_util`, including suffix forms and dotfiles.

`unapproved_additions` returns every refused protected path in `files`.
