# Dev round schema

The on-disk record of a round's kind, consumer validation declaration, starting commit, and allowed protected additions. Fix rounds also carry their delegated items. The orchestrator writes it with `dev-round-write` immediately after minting the round token and before sending the delegation.

For a chosen cut, see [§ Declared cuts](#declared-cuts).

## Identity: the round id

Optional `finding_occurrences` stores the pre-stamp `workflow-state findings query` result unchanged, supplied by `--finding-occurrences-file`. It is part of this record's immutable input, not a permission or another counter. Missing on legacy records remains supported. The source/count contract is [workflow-state.md § Finding occurrences](workflow-state.md#finding-occurrences).

The record is `[WORKTREE_PATH]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` and carries `"round_id": ROUND_ID`; readers require a regular file — never a symlink — whose internal token, issue, and schema match what they were called with.

The record sits inside the delegated worktree, so it is trusted the way every other instruction to that agent is: the orchestrator writes it before delegating, and the delegated agent is trusted not to edit it. Immutability is enforced against a second `dev-round-write` invocation, not against the agent holding the worktree.

`[ISSUE_ID]` is the normalized workflow-state key — dev-side workflows name the same value `[ARTIFACT_KEY]`, and a bundled round uses the Parent ID. It and `[ROUND_ID]` must match `^[A-Za-z0-9._-]+$` with no `..`.

## Schema

```json
{
  "schema_version": 2,
  "round_id": "1769600000123456789-1837",
  "kind": "fix",
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
| `kind` | New records | `--kind` | `implement` or `fix`; default `fix` preserves existing callers |
| `validation_policy` | Optional | `--validation-input` | Bound consumer declaration under [Validation input](#validation-input) |
| `schema_version` | Yes | constant `2` | Record schema version |
| `round_id` | Yes | `--round-id` | Per-delegation token; equals the filename token and the round's `dev_round_id` |
| `issue` | Yes | `--issue` | Normalized workflow-state key |
| `base_sha` | Yes | captured from `HEAD` | Commit at delegation time; exactly 40 lowercase hex with nothing before or after, and readers refuse anything else — it reaches `git diff` as a revision argument |
| `delegated_at` | Yes | captured from the clock | Epoch second the round's first `dev-round-write` invocation started. An identical retry keeps it: identity compares every other field |
| `adds` | Yes | `--adds "PATH [PATH...]"` | Exact protected additions the round may make; an empty array allows none in the protected scope |
| `cut` | Yes | `--cut` | Whether the round was declared a branch cut. Readers treat a missing or `null` `cut` as `false`, and refuse any other non-boolean value |
| `source` | Yes | `--source NAME` | The delegation's `Source:` value; null when the flag is absent |
| `pr_open` | Yes for new records | `--pr-open true\|false` | Whether the pull request was open at delegation. Defaults to `false`; readers treat an absent field as `false` and refuse a non-boolean value. A fix round requests `ci` when this is `true` or `pr-order` resolves `push-first`, regardless of `source`; otherwise it requests `range`. The runner may fall back to local validation. `dev-artifact-check` accepts a `ci` receipt under the same rule, only for the current HEAD. Acceptance completes the local edits; required CI remains pending until submit's exact-head wait |
| `items` | Yes (empty for `implement`, >=1 for `fix`) | `--items-file` or `--item N TEXT REACH` | `n` is the delegated item number (a unique integer >= 0), `text` the item's formatted block verbatim, `reach` the shipped producer, user action, or fixture that reaches the finding |

`--items-file` is the default route: build the array with the harness file-write tool. The inline `--item N TEXT REACH` form is equivalent when every item's text is plain, with `N` a canonical integer. The two sources are mutually exclusive; `dev-round-write --help` is the flag reference.

## Validation input

Read before stamping or consuming a policy-bearing round. `dev-round-write --kind implement|fix --validation-input FILE` reads one transient JSON request with `route`, `mode`, `authority` and `workload`. The orchestrator writes the request from the consumer's actual instructions and task authority. `authority` names the exact instruction path, blob/source revision and any durable task directive. `workload` names the actual entry point, native arguments, wrapper, environment and slot constraints. These strings are trusted delegation input, not commands to execute or evidence that work ran.

The writer stores this declaration as `validation_policy` in the existing immutable round record. It adds `source_head` and effective command, selector and timeout identities from `orch-env`. It adds no policy registry or command override. `configured` uses those unchanged settings. `native` uses the declared consumer entry point through its existing permitted lifetime owner and requires a `full` or `range` workload; a mode label alone proves no battery. `dev-validate-run --check-policy --round-record FILE --worktree PATH` is the shared reader. It refuses changed effective identities. Callers keep the original record and actual input/base; a restack or publication does not mint a new round or replenish execution.

`dev-validate-run --resolve-action --round-record FILE --worktree PATH` returns the permitted action, actual mode, effective bound and optional estimate. `reuse` names supported existing invocation proof; `no-verdict` names the earlier bound result and starts nothing. Consumers use that action and the receipt checker. They do not infer native permission from the absence of a range command. Missing complete dependency evidence keeps proof conservative. This form supplies no composite proof.

New records carry `kind`. An absent `kind` on a legacy record means `fix`; an absent record retains the legacy implementation route. An implementation has `items: []`. Fix items and protected-addition gates retain their existing meaning. Acceptance of either stamped kind uses `--expect-items-from-round`. `round-recover` uses that same kind for its report parser and checker flags, so a completed implementation keeps its original round.

## Item text

Stored `text` starts with `#[N] | [AGENT] | [LOCATION]` on its first line. Copy the header and that item's fields verbatim. When the finding has an `owner`, put `Owner: [OWNER]` after `Recommendation:`; omit that line otherwise. Exclude outer `---` separators, leading blank lines, code fences and delegation headings from stored text. This contract applies to both `--items-file` and inline `--item` text.

**`reach` is required per item, on both routes.** It names what reaches the finding: a command a person runs, a file a shipped writer emits, a test in the tree. An item with no reach is a `Declined:` reply, not a fix.

The item's keys are its location, the text after the second `|` on the first line of `text`, and its optional owner, the text after `Owner:` on the first later line that begins with it. An entry's keys are its `location` and optional `owner`. The shared module `scripts/lib/cause-keys.jq` defines these keys and their match for the recorded-round count. Blanks at both ends are removed; empty, `TBD` and `general` values are not keys. Case, path and symbol remain unchanged. An item matches an entry when they share any key, including an owner equal to a location. Older entries without `owner` still match by `location`.

An item that prescribes a mechanism tells the delegate to measure it first and report a mismatch instead of complying.

What the writer itself refuses is a short list, not a scanner: an empty or whitespace-only reach, a `PRRT_` review-thread node id anywhere in the value, and a few literal values. A value outside those shapes is recorded, not approved. The classes [`../references/finding-disposition.md` § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow) excludes at Step 0 are the orchestrator's judgement at disposition time, before any round is delegated; [`tests/dev_round_write.sh`](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/tests/dev_round_write.sh) pins the writer's verdict.

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

`base_sha` records the round's starting tree: a file already there is not this round's, so a later round does not re-refuse an addition an earlier one authorized. When a rebase orphans that commit, `dev-artifact-check` projects only its comparison value through the worktree-private ordered `kendex-rebase-map`, using `scripts/lib/rebase-map.sh`. The complete map must prove a commit in `HEAD` ancestry. The gate then compares that rewritten starting tree, which already contains upstream additions, against `HEAD`. It changes neither the original round record nor the map. A missing, unresolved, malformed, incomplete, dropped or unrelated projection refuses with `reason: "additions_unattributable"` and empty `files`.

That refusal is not a deferral. A fresh round starts at the current `HEAD`, which already carries the prior round's additions. Without proved correspondence, settle those additions by reading the original round's own commits against the scope below. The orchestrator then mints a fresh round, names each deliberate path in `Adds:`, and cuts the rest before delegating it. That line authorizes those existing paths; the fresh round's gate cannot re-derive them. Map correspondence alone proves no validation result: the writer still binds the actual run to the original base and delegation time under [dev-return.md](dev-return.md).

Protected additions are:

- root `crates/` and `tools/`;
- `skills/*/scripts/` and `.agents/skills/*/scripts/`;
- root or nested `src/test/`;
- directories named `helper`, `helpers`, `test-helper`, `test-helpers`, `test_helper`, `test_helpers`, `test-util`, `test-utils`, `test_util`, or `test_utils`;
- any later `helper`, `helpers`, `lib`, `support`, `util`, or `utils` directory component after a `test`, `tests`, or `__tests__` component, regardless of intervening suite directories;
- repository-relative paths containing `test-helper`, `test_helper`, `test-util`, or `test_util`;
- files below a `test/`, `tests/`, or `__tests__/` path component whose basename before the first extension contains lowercase `helper`, `test-util`, or `test_util`, including suffix forms and dotfiles.

`unapproved_additions` returns every refused protected path in `files`.
