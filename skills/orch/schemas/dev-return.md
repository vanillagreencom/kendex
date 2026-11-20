# Dev Return (Completion Artifact) Schema

Read when writing, checking or accepting a dev round's receipt. The agent of an implement or fix delegation writes the receipt at the end of its round. Orch accepts the round from this file and git, never from the agent's return message.

`orch-runtime dev-return --text write` is the one writer. Never write or edit a receipt with a file tool. The writer builds the JSON, publishes it atomically, and refuses with one keyed line ([§ Writer refusals](#writer-refusals)). `orch-runtime dev-return --text check` judges a receipt. [artifact-checks.md § Receipt check answers](../references/artifact-checks.md#receipt-check-answers) lists its answers; the delegating workflow routes them.

## Identity: the round id

Each delegation's `Round ID:` line carries the round token orch minted through `begin-round` (`dev_round_id`). The receipt's name and `round_id` bind it to that token. Its name binds it to the run it reports:

- `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID]-[RUN_ID].json` where `--validate-run-dir` names a run. `[RUN_ID]` is the run directory's name without its `dev-validate-` prefix.
- `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json` where no run directory is named.

`dev-return --text check --round-id RID` requires the receipt's `round_id` to be `RID` and its `issue` to be the `--issue` key. Otherwise it answers `invalid`.

After a run that ended without a pass, the runtime admits the round's next attempt ([dev-implement.md § 5](../../dev/workflows/dev-implement.md#5-validate)). That run writes its own receipt under its own run id, beside the first. The writer never replaces a failing receipt: at a path that holds one it refuses `receipt-exists`. A foreground attempt interrupted before its record completed writes a `FAILING` receipt under the no-run name. That receipt has `validate_mode` and `validate_time` null, names no evidence source, and names the interruption in `validate_note`.

The check selects the receipt it judges:

- **Round mode** (`--worktree`, `--issue`, `--round-id`). Where the round has an admitted `validate` stage, the check takes the receipt of the run the newest stage names. Otherwise it takes the round's one receipt under either name; two or more refuse `receipt-ambiguous`. The reply's `path` names the selected receipt, which acceptance and submit consume.
- **File mode** (`--file`). The named file, an earlier attempt's receipt included.

A fix round also has an input record bound by the same token, `[WORKTREE_PATH]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json`. Orch stamps this delegated item set before delegating. `--expect-items-from-round` checks the receipt's `items[]` against it. Its schema is [dev-round.md](dev-round.md).

`[ISSUE_ID]` is the workflow-state key where one exists ([workflow-state.md § Keys](workflow-state.md#keys)). A bundled delegation uses the parent's key. Ad-hoc work takes a `local-` key from `orch-runtime state new-local-key`, never an empty or free-form string. That command writes nothing, so work with no state step can still name its receipt. The key and `[ROUND_ID]` must match `^[A-Za-z0-9._-]+$` with no `..`.

## Schema

```json
{
  "schema_version": 1,
  "round_id": "1769600000123456789-1837",
  "kind": "implement",
  "issue": "PROJ-123",
  "branch": "user/proj-123",
  "commit": "abc123f0d4e5b6a7c8d9e0f1a2b3c4d5e6f7a8b9",
  "baseline_lines": 138,
  "validate": "FAILING: cargo test",
  "validate_mode": "full",
  "validate_time": { "started_at": "2026-01-01T00:00:00Z", "ended_at": "2026-01-01T00:55:00Z", "seconds": 3300 },
  "validate_note": "Test-only validation ceiling: the suite failed at 34m; the failed target passed alone under load",
  "qa_labels": ["needs-review"],
  "near_ceiling": ["byte-ceiling: near-ceiling=assets/demo.bin:189000:204800:92"],
  "near_ceiling_error": null,
  "screenshots": ["/home/dev/wt/tmp/ui-shots/settings-after-dark.png"],
  "summary_posted": true,
  "summary": "### Proposed Rules\n- Rule the validation list is missing",
  "recovered_from": null,
  "bundled": false,
  "items": [
    { "n": 1, "decision": "Applied", "reasoning": "Fixed nil deref in empty buffer" }
  ]
}
```

## Fields

| Field | Required | Writer flag | Meaning |
|-------|----------|-------------|---------|
| `schema_version` | Yes | (constant `1`) | Receipt schema version, a number. |
| `round_id` | Yes | `--round-id` | The round's token. It equals the name's token and the expected `dev_round_id`. |
| `kind` | Yes | `--kind` | `implement` or `fix`. |
| `issue` | Yes | `--issue` | The normalized workflow-state key; the parent's when bundled. |
| `branch` | Yes | `--branch` | The git branch, a non-empty string. |
| `commit` | Yes | `--commit` | The full 40-hex name of the commit `--commit` names: HEAD after the round's commit, or the prior HEAD where the round needed no commit. A `not-run` receipt records the HEAD the round was delegated at. The writer resolves the text in the worktree and refuses one that names no commit as `commit-unresolvable`. |
| `baseline_lines` | `implement` | measured by the writer | The branch's churn at `commit`, as change-scope's `branch_baseline_lines` measures it (`skills/change-scope/scripts/lib/branch-growth.sh`), floored at 1. It authorizes no fix round. Absent on a `fix` receipt. |
| `validate` | Yes | `--validate` | `pass`, `no-verdict`, `not-run`, `handed-over` or `FAILING: check1,check2`, a closed set. § [`validate` and its note](#validate-and-its-note) gives each word's evidence rule. |
| `validate_mode` | Yes | read from `--validate-run-dir` or `--validate-record` | The mode of the named run. `full` is the whole battery, which may run scoped suites. `range` is a fix round's changes since its base. `docs` is a docs-only snapshot's declared text checks. `ci` is completed local edits with required CI pending. A run directory reports the mode through `orch-runtime validate entry --record`; a [foreground validation record](#foreground-validation-record) states `full` or `range`. `null` only beside a `FAILING`, `not-run` or `handed-over` receipt that names no run. |
| `validate_time` | Yes | read from `--validate-run-dir` or `--validate-record` | The run's wall time: `started_at` and `ended_at` in UTC, and `seconds` between them. A `no-verdict` run carries one too. `null` where no run is named or the run left no timing, so only beside a `FAILING`, `not-run` or `handed-over` receipt. The check answers `invalid` for a time beside a `null` mode, a wrong type, or seconds that are not the span. |
| `validate_lanes` | Optional | read from the run | Comma-separated lane names from the command's [output contract](../references/artifact-checks.md#validation-command-output). Absent where unreported, where the selection is the start's preview, or where no run is named. |
| `validate_selection` | Optional | read from the run | `all`, `subset`, `battery` or `unreported`. Absent where no run is named. It changes neither `validate_mode` nor the verdict. |
| `validate_class_base` | Optional | read from `--validate-run-dir` | The run record's `class-base`: the base a scoped run judged its class from. That is the request's base, or the branch merge base where the request names none. The runtime's proof reader (`orch-runtime read-proof`) decides whether submit reuses the run. Absent for whole-branch validation and for a `ci` run that ran no command. |
| `validate_tree` | `FAILING` `fix` receipt with a run | read from the run | The tree the run validated, which may hold staged work `commit` does not ([§ Fix-round run binding](#fix-round-run-binding)). Absent on every other receipt. |
| `validate_note` | Optional | `--validate-note` | A qualifier the closed set cannot express, or `null`. Required beside `no-verdict`, where it names the host cause or the stop that ended the run. |
| `qa_labels` | Optional | `--qa-label`, repeatable | The applied QA labels; `[]` where none. |
| `near_ceiling` | Optional | `--near-ceiling-base` | One `byte-ceiling: near-ceiling=` line per binary blob within reach of the byte ceiling. The writer runs the worktree's installed `.agents/skills/commit-guards/scripts/byte-ceiling --base REF` and keeps those lines on exit 0 or 1. A repository with nothing at the lane path has no byte ceiling and records `[]`. Every other outcome records `null`, which means unknown, never none. The list describes the branch at receipt time; a blob that enters the warn band later is not in it. Orch stores the list as workflow state's `near_ceiling` for the next round's brief. |
| `near_ceiling_error` | Optional | set by the writer | Why `near_ceiling` is `null`, in the writer's words. `null` otherwise. |
| `screenshots` | Optional | `--screenshot`, repeatable | The round's captures as absolute paths. The writer refuses a path that is not a readable file as `screenshot-unreadable`. Absent where none is named. The acceptance's `accept-result` attaches each to the item's summary comment. |
| `summary_posted` | Optional | `--no-summary` sets `false` | `true` unless the writer got `--no-summary`: a GitHub or ad-hoc round, or a receipt `round --text recover` wrote. The runtime reads no decision from it. |
| `summary` | Optional | `--summary`, `--summary-file` or `--recovered-text` | The round's summary, or `null`. Every single implement round embeds it, so a consumer can read its `### Proposed Rules`. |
| `recovered_from` | Optional | `--recovered-text` sets `"transcript"` | `"transcript"` where `orch-runtime round --text recover` wrote the receipt from a stalled agent's transcript, with that report as `summary`. `null` otherwise. |
| `bundled` | Optional | `--bundled` sets `true` | `true` for a bundled implement round. |
| `items` | Conditional | `--item N DECISION REASONING`, repeatable | Per [§ Kind rules](#kind-rules). |
| `no_change` | `not-run` | `--no-change` | The item's sentence that permits ending the round with no change, as the worker quoted it ([§ No-change receipt](#no-change-receipt)). Absent on every other receipt. |
| `exception` | Beside a cited exception | `--exception-file` | The exception `{by, id, excused}` the round began with, cited beside a `FAILING` run ([§ Exception](#exception)). Absent otherwise. |

The check echoes the `validate` and `validate_*` fields, `near_ceiling`, `near_ceiling_error`, `screenshots` (`[]` where absent), `no_change` and `exception`, each `null` where the receipt lacks it.

## Kind rules

Each `items[]` element is `{n: number, decision: "Applied"|"Skipped"|"Blocked", reasoning: string}`. `n` is the review item's `#N` or the sub-issue index, each number once. `reasoning` is non-empty; a `Skipped` one cites the decision id or rule.

| Case | `items` |
|------|---------|
| `implement`, single | May be empty: `items: []` |
| `implement`, `--bundled` | Non-empty, one entry per sub-issue result |
| `fix` | Non-empty, one entry per delegated review item; `--expect-items-from-round` requires the set to match the round record exactly |

## `validate` and its note

`validate` records the final run's verdict. The note never relaxes it. [dev-implement.md § 5](../../dev/workflows/dev-implement.md#5-validate) owns the permitted correction and rerun routes and the notes they require:

```bash
--validate "FAILING: cargo test" --validate-note "Test-only validation ceiling: the suite failed at 34m; the failed target passed alone under load"
```

| Word | Evidence the writer needs |
|------|---------------------------|
| `pass` | Exactly one of `--validate-run-dir` and `--validate-record`, whose verdict is `pass`, or a `ci` run whose verdict is `pending`. A `ci` pass's run snapshot must be the commit's tree, or the writer refuses `ci-contents-mismatch`. Required CI then proves the head; the merge-group run does so where the run record carries `ci-event=merge_group`. |
| `no-verdict` | One evidence source whose run ended `no-verdict`, and a `--validate-note` naming the host cause or the stop that ended it. It is neither a pass nor a failure ([artifact-checks.md § Validation command output](../references/artifact-checks.md#validation-command-output)). Only a `no-verdict` in the `ci` mode leaves its proof to required CI; any other is unproved. |
| `FAILING: …` | Any run verdict, or no evidence source. The names are the failing checks, comma-separated. |
| `not-run` | No evidence source; [§ No-change receipt](#no-change-receipt). |
| `handed-over` | No evidence source; [§ Hand-over receipt](#hand-over-receipt). |

The writer refuses a `--validate` that differs from the named run's verdict as `validate-disagrees`, a `FAILING` one aside. It refuses an empty or whitespace-only note or summary as `empty-text`.

### Fix-round run binding

A `fix` receipt that names a run must bind it to its round record ([dev-round.md](dev-round.md)), or the writer refuses `run-off-round`:

- A `pass` or `no-verdict` run validated the receipt's committed tree. A `FAILING` run binds over the tree it ran, staged work included, and the receipt stores that tree as `validate_tree`.
- The run's HEAD contains the record's `base_sha`; or the base's tree is the run's tree; or the run's start record names that base as its `validate-base`; or the run's HEAD contains the base's rewritten commit in the worktree-private `kendex-rebase-map` (ordered hops per [workflow-state.md](workflow-state.md), `rebase_map` row). Where no map file stands, the rewritten commit is the first one the item record's `rebase_map` maps the base to, hop by hop, that the worktree's HEAD contains.
- A run directory whose start record names no tree, and a foreground record, prove their recorded HEAD's tree only while that HEAD is the worktree's HEAD and `git status --porcelain --untracked-files=all` prints nothing.
- A `pass` also needs the round's proof: the runtime's proof reader, as `read-proof --need round` reads it, answers the tree `complete` or `pending`. A `no-verdict` needs the run itself to have ended `no-verdict`.

The check then holds the receipt's mode to the round. A run the runtime started carries its mode on the round's admitted `validate` entry (`proof`); a receipt recording another mode answers `mode_mismatch`. A receipt whose run has no admitted entry, an ad-hoc run or a foreground record, may record any mode but `ci`. It may record `ci` only on a round whose record carries `pr_open: true` or whose `pr-order` resolves `push-first`. Submit's reuse of a pass is its own: [submit-pr.md](../workflows/submit-pr.md) § 1.1.

### Apple gate

The gate reads `ORCH_APPLE_WORKFLOW` and the space-separated `ORCH_APPLE_LABELS` ([settings.md § Validation](../references/settings.md#validation)) from the project settings. It judges every receipt but a `FAILING` or `not-run` one, and only where the base branch holds the configured workflow:

- The receipt declares the item's labels: one `--label` per entry of the brief's `Labels:` line, or `--no-labels`. The writer refuses an undeclared receipt as `labels-undeclared`.
- The item touches Apple work where a label is one of `ORCH_APPLE_LABELS`, or a changed path sits under `ios`, `macos`, a `.xcodeproj` or a `.xcworkspace`. A changed `Package.swift` that names `.iOS` or `.macOS` counts, as does a changed path with a part an Xcode project's file references name, at the merge base or at the commit. An unreadable project file counts as Apple work.
- Such an item records its passing run as one `validate_note` line, `mac run test: pass run=RUN_ID`, beside any other note text. Without the line the writer refuses `mac-run-missing`. A failed or absent run is `FAILING: mac run test`, which needs no line.

The receipt does not record the labels.

## No-change receipt

A round whose item permits ending it with no change, and whose comparison finds none needed, writes `--validate not-run --no-change TEXT`. `TEXT` is the item's sentence that permits it, quoted from the item's description. The writer admits the receipt only where each of these holds:

- The round is a single `implement` round, with no `--bundled` and no `--item`.
- The key is a Linear identifier or a GitHub issue's `issue-N`. Any other key, such as a `local-` or a `directive-` key, refuses `no-change-unverifiable`. An `issue-N` key's repository is the worktree's own; a worktree that names none refuses `repo-unresolved`.
- `--commit`, the worktree's HEAD and the item's recorded `pre_delegate_sha` are one commit, and `git status --porcelain` prints nothing.
- No `--validate-run-dir` or `--validate-record` is named, and a summary is. The summary is the comparison, which the acceptance posts as the item's Completion Summary.
- The item's live description holds `TEXT`, with runs of whitespace folded. The writer reads a Linear item through the tracker CLI's `issues get ID --format=safe`, and a GitHub issue through `gh issue view N --repo R --json body,labels`. A failed read refuses `item-unread`, never `no-change-unpermitted`.

The writer proves only that the sentence is the item's. The acceptance in [dev-start.md § 3](../workflows/dev-start.md#3-accept-the-round) judges whether it permits the end. The check answers `no-change` for a valid receipt. It answers `retry` with reason `head_moved` where the receipt's `commit` is no longer the worktree's HEAD.

## Hand-over receipt

In a grouped round, each group but the last commits its work and writes `--validate handed-over`. The next group takes the work and validates. The writer admits the receipt only where each of these holds:

- The receipt is a `fix` receipt, a `--bundled` one, or one that names `--item`s; otherwise `handover-kind`.
- The round's stage records a `group` that is not the last, as `begin-round` recorded it; otherwise `handover-final`, with the group or `group=unrecorded`.
- The commit differs from its base and descends from it; otherwise `handover-unmoved`. A fix hand-over's base is the stamped round's `base_sha`. An implementation hand-over's base is the item's recorded `pre_delegate_sha`.
- No evidence source is named.

The check answers `hand-over` for a valid receipt. The runtime does not judge the worktree's cleanliness on a hand-over; the acceptance's Check B does.

## Exception

A round may begin with an exception: `{"by": "overseer"|"owner-directive", "id": ID, "excused": [CHECK, …]}`. It lists the known failing checks the delegating side grants, each named as a `FAILING:` list names it. A worker never grants one. Beside a `FAILING` run, `--exception-file FILE` cites the exception the round began with, and the receipt keeps its `FAILING` line:

- The receipt's `validate` must be `FAILING: …` and name a run or a record; otherwise `exception-run`.
- FILE must hold an exception with a non-empty `id` and at least one check, each name trimmed and holding no comma; otherwise `exception-invalid`.
- FILE must equal the exception the round's stage recorded; otherwise `exception-unbegun`.

The check answers `accept-excused` where the exception excuses every failing check. It answers `exception_unbegun` where the cited exception is not the round's.

## Foreground validation record

Some projects run their validation entry point in the foreground by their own policy and forbid orch's validation runner. Such a project names its run with `--validate-record FILE` in place of `--validate-run-dir`; the writer takes only one of the two. FILE holds one `KEY=VALUE` per line in the grammar `orch-runtime dev-return --text write --help` prints, `head=` being the HEAD the run started at.

The writer reads the record into the fields a run directory fills, so the receipt has the same shape on either route. It derives the wall time from the two times. With the `verdict=no-verdict` marker the verdict is `no-verdict`. Otherwise exit 0 is `pass` and any other exit is a failure. A `fix` receipt binds the record to its round as it binds a run directory ([§ Fix-round run binding](#fix-round-run-binding)). The record file stays where the project wrote it; the receipt does not copy its head or exit status.

## Writer refusals

`orch-runtime dev-return --text write` writes nothing on a refusal. It exits 2 with one `dev-return: KEY CAUSE` line on stderr, which names the key and its cause. Without `--text` the reply is `ok: false` with the key, exit 1. The sections above name the keys a writer must avoid.
