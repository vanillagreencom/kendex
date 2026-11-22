# Dev round schema

Read when writing a fix round, checking its receipt, or recovering a respawned agent's item set. The record holds a fix round's delegated items, its starting commit and the protected additions it may make. The orchestrator writes it with `orch-runtime round --text stamp`, after minting the round token and before sending the delegation. A chosen cut follows [§ Declared cuts](#declared-cuts).

## Identity: the round id

The record is `[WORKTREE_PATH]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` and carries `"round_id": ROUND_ID`. A reader requires a regular file, never a symlink, whose `round_id`, `issue` and schema match its call.

The record sits inside the delegated worktree. The agent trusts it as it trusts every other instruction: the orchestrator writes it before delegating, and the agent does not edit it. Immutability holds against a second stamp of the round, not against the agent that holds the worktree.

`[ISSUE_ID]` is the normalized workflow-state key. The dev package's workflows call it `[ARTIFACT_KEY]`; a bundled round uses the parent's key. It and `[ROUND_ID]` must match `^[A-Za-z0-9._-]+$` with no `..`.

The optional `finding_occurrences` holds the `result` of the pre-stamp `orch-runtime state findings query` reply unchanged, from `--finding-occurrences-file`. It is immutable input, not a permission or a counter. A record without it has none. [workflow-state.md § Finding occurrences](workflow-state.md#finding-occurrences) owns its source and count contract.

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

| Field | Required | Writer flag | Meaning |
|-------|----------|-------------|---------|
| `schema_version` | Yes | constant `2` | Record schema version |
| `round_id` | Yes | `--round-id` | The round's token |
| `issue` | Yes | `--issue` | The normalized workflow-state key |
| `base_sha` | Yes | read from `HEAD` | The commit at delegation |
| `delegated_at` | Yes | read from the clock | The epoch second of the round's first stamp |
| `adds` | Yes | `--adds "PATH [PATH...]"` | The exact protected additions the round may make |
| `cut` | Yes | `--cut`, or the `round cut` verb | Whether the round was declared a branch cut |
| `source` | Yes | `--source NAME` | The brief's `Source:` value |
| `pr_open` | Yes for new records | `--pr-open true\|false` | Whether the pull request was open at delegation |
| `items` | Yes, at least one | `--items-file` or `--item N TEXT REACH` | The delegated items |

- `round_id` equals the name's token and the round's `dev_round_id`.
- `base_sha` is exactly 40 lowercase hex characters. A reader refuses anything else.
- `delegated_at`: an identical retry keeps it; identity compares every other field.
- `adds`: an empty array allows none.
- `cut`: a reader takes a missing or `null` `cut` as `false` and refuses any other non-boolean.
- `source` is `null` without the flag.
- `pr_open`:
  - It is `false` by default.
  - A reader takes an absent field as `false` and refuses a non-boolean.
  - It is a recorded fact, read only for a receipt whose run has no admitted entry ([dev-return.md § Fix-round run binding](dev-return.md#fix-round-run-binding)).
- `items`:
  - `n` is the delegated item number, a unique integer.
  - `text` is the item's formatted block verbatim.
  - `reach` is the shipped producer, user action or fixture that reaches the finding.

`--items-file` is the default route: build the array with the harness file-write tool. The inline `--item N TEXT REACH` form is equivalent where every item's text is plain and `N` is a canonical integer. The writer takes one of the two. `orch-runtime round --text stamp --help` is the flag reference.

## Item text

The rules below hold for `--items-file` and inline `--item` text alike:

1. Stored `text` starts with `#[N] | [AGENT] | [LOCATION]` on its first line.
2. Copy the header and that item's fields verbatim.
3. Where the finding has an `owner`, put `Owner: [OWNER]` after `Recommendation:`; otherwise leave the line out.
4. Leave out outer `---` separators, leading blank lines, code fences and delegation headings.

Every item needs a `reach`, on both routes. It names what reaches the finding: a command a person runs, a file a shipped writer emits, a test in the tree. An item with no reach is a `Declined:` reply, not a fix.

An item has two keys:

- Its location: the text after the second `|` on the first line of `text`.
- Its optional owner: the text after `Owner:` on the first later line that starts with it.

A ledger entry's keys are its `location` and optional `owner`. The runtime's `cause_keys` (`skills/orch/runtime/src/watch/lanes.rs`) reads them for the repeated-class count:

- It trims blanks at both ends.
- An empty, `TBD` or `general` value is no key.
- Case, path and symbol stay as written.
- An item matches an entry where they share any key, an owner equal to a location included.

An item that prescribes a mechanism tells the delegate to measure it first and to report a mismatch instead of complying.

The writer refuses an empty reach, a review-thread node id and a short list of placeholder values, such as `the finding`, as `reach-refused`. That list is not a scan: the writer records any other value, and recording is not approval. The orchestrator judges the classes [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow) excludes at Step 0 at disposition time, before any round is delegated.

The brief's `Adds:` line and `--adds` carry the same blank-separated path list:

- A blank or a tab separates paths, so a path holding whitespace cannot be authorized.
- The writer and the reader refuse a path that is absolute, starts with `-`, holds whitespace, has an empty, `.` or `..` component, or repeats.
- Where the round may add nothing, leave out both the line and the flag.

## Immutability and the live round

The record is immutable per round. A second stamp of the round with any other field changed refuses `record-conflict`; an identical retry stands. Mint a new round instead, and never fall back to an unbound item list.

The live round is the record of the round workflow state names as `dev_round_id`, while no receipt of that round stands beside it, bare or keyed by its run.

- During it, `record-push` refuses to push as `live-round`.
- Its `check-live-round` mode answers exit 3, which refuses the restack: a rebase would move the branch off the commit that round works from.
- The receipt landing ends the live round. So does a fresh `dev_round_id` whose token names no stamped record.

## Declared cuts

A reviewer or the orchestrator chooses a cut, and the work it cuts, to bring the branch back to the Done-when. `orch-runtime dev-return --text check --expect-items-from-round` checks the cut round's receipt against the record.

A cut item names work, not a finding, so its reach is the branch the round shrinks. The reach is still required, and the writer still refuses an empty or placeholder one.

- `--cut` records `"cut": true`.
- Acceptance checks the item set, the reach, the protected additions and immutability. Branch line counts do not decide acceptance.
- A fresh retry repeats `--cut` and delegates the remaining work.

## Readers

- `orch-runtime dev-return --text check --expect-items-from-round` derives the expected items and additions from the record. [artifact-checks.md § Receipt check answers](../references/artifact-checks.md#receipt-check-answers) states its answers.
- `orch-runtime dev-return --text write --kind fix` reads `base_sha` and binds the receipt's run to it, or refuses `run-off-round` ([dev-return.md § Fix-round run binding](dev-return.md#fix-round-run-binding)).
- `orch-runtime round --text recover` reads the record to parse a stalled fix round's report.
- A respawned dev agent reads `items[]` to recover the item numbers, texts and reaches. The fix round's report-only nudge points at the record.

The record is input, never a receipt. It proves what was delegated, not that anything completed. [dev-return.md](dev-return.md) and the acceptance tables own completion.

## Protected additions

The gate checks additions only. Git's rename detection keeps moves and renames outside it.

`base_sha` records the round's starting tree. A file already there is not this round's, so a later round does not refuse an addition an earlier round authorized.

Where a rebase moved that commit off the branch, the receipt check projects it to a rewritten commit in `HEAD`'s ancestry:

1. It reads the worktree-private ordered `kendex-rebase-map` whole, through the runtime's one map reader.
2. Where no map file stands, it follows the item record's `rebase_map` hop by hop.
3. It then compares that commit's tree, which already holds upstream additions, with `HEAD`.

It changes neither the record nor the map. A missing, unresolved, malformed, incomplete, dropped or unrelated projection answers `reason: "additions_unattributable"` with empty `files`.

That answer is not a deferral. A fresh round starts at the current `HEAD`, which already carries the earlier round's additions, so the fresh round's gate cannot derive them again. Settle them first:

1. Read the earlier round's own commits against the scope below.
2. Mint a fresh round.
3. Name each deliberate path in `Adds:`. That line authorizes those standing paths.
4. Cut the rest before delegating it.

A map correspondence proves no validation result; the writer still binds the actual run to the round's base and the receipt's tree.

Protected additions are:

- root `crates/` and `tools/`;
- a `scripts` directory anywhere under `skills/` or `.agents/skills/`;
- a `src/test/` pair of directories, at the root or nested;
- a directory named `helper` or `helpers`;
- a `lib`, `support`, `util` or `utils` directory after a `test`, `tests` or `__tests__` component, whatever directories lie between;
- a repository-relative path holding `test-helper`, `test_helper`, `test-util` or `test_util`;
- a file below a `test/`, `tests/` or `__tests__/` component whose basename before its first extension, a leading dot removed, holds lowercase `helper`, `test-util` or `test_util`.

`unapproved_additions` returns every refused protected path in `files`.

## Stamp refusals

`orch-runtime round --text stamp` writes nothing on a refusal. It exits 2 with one `round: KEY CAUSE` line on stderr, which names the key and its cause. Without `--text` the reply is `ok: false` with the key, exit 1. A `record-conflict` means a record for this round stands with other content: mint a fresh round ([§ Immutability and the live round](#immutability-and-the-live-round)).
