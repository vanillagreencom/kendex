# Dev Return (Completion Artifact) Schema

The receipt a dev or QA agent writes at the end of an implement or fix delegation. Orch accepts the round from this file and git state, never from the agent's return message.

`orch-runtime dev-return --text write` is the one writer; the receipt is never hand-authored or composed with a file tool. The writer builds the JSON itself, writes it atomically and refuses what [§ Writer refusals](#writer-refusals) lists. `orch-runtime dev-return --text check` judges it, and [`../references/artifact-checks.md`](../references/artifact-checks.md) lists its answers and routes the verdict.

Every `implement` receipt carries the branch's additions plus deletions at its commit as `baseline_lines`, binary rows and mandated render mirrors left out, floored at 1. The shared branch measurement pairs a render with the source it renders, so a source with a tracked render counts once. The value measures churn; it authorizes no fix round. CI reads the same measurement to classify a change and choose its checks.

## Identity: the round id

Each delegation carries the round token orch minted (`dev_round_id`, through `orch-runtime` `begin-round`) on its `Round ID:` line. The receipt is bound to that token twice, and to the run it reports once. Its filename is `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID]-[RUN_ID].json`, `[RUN_ID]` the id of the run directory `--validate-run-dir` names (`dev-validate-[RUN_ID]`), or `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json` where it names no run, and it carries `"round_id": ROUND_ID` inside. `orch-runtime dev-return --text check --round-id RID` requires the internal token to match.

A later run of the same round, which the runtime admits as the round's next attempt after a run that ended without a pass ([dev-implement.md § 5](../../dev/workflows/dev-implement.md#5-validate)), writes its own receipt under its own run id beside the first. A failing receipt is never overwritten: the writer refuses `receipt-exists` for a path that holds one. Round mode reads the receipt of the run the round's newest `validate` stage names and returns its `path`; the earlier receipt stays readable in file mode, with its native run record. File mode checks its named file. Acceptance and submit consume the selected path. A later run can name the same implementation commit.

A foreground attempt interrupted before its record completed writes a `FAILING` receipt under the round's no-run name, with `validate_mode` and `validate_time` null, both evidence flags omitted and the interruption named in `validate_note`. The attempt's unfinished record and log stay where the project wrote them. The checker refuses acceptance on that receipt, and the writer refuses a second receipt under the same name.

Fix rounds have an input-side sibling bound by the same token, `tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json`, the delegated item set the orchestrator persists at stamp time; `--expect-items-from-round` checks this receipt's `items[]` against it. Schema: [`dev-round.md`](dev-round.md).

`[ISSUE_ID]` is the workflow-state key where one exists ([workflow-state.md § Keys](workflow-state.md#keys)); a bundled delegation uses the Parent ID. An ad-hoc id is a `local-` key from `orch-runtime state new-local-key`, never an empty or free-form string. That command writes nothing, so ad-hoc work that runs no state step uses the key to name the receipt alone. [`review.md` § 4](../workflows/review.md#4-present-and-fix) mints one for a review of a branch carrying no issue id and inits state under it. Both, and `[ROUND_ID]`, must match `^[A-Za-z0-9._-]+$` with no `..`.

## Schema

```json
{
  "schema_version": 1,
  "round_id": "1769600000123456789-1837",
  "kind": "implement",
  "issue": "PROJ-123",
  "branch": "user/proj-123",
  "commit": "abc123f",
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

| Field | Required | Writer flag | Description |
|-------|----------|-------------|-------------|
| `schema_version` | Yes | (constant `1`) | Artifact schema version (number) |
| `round_id` | Yes | `--round-id` | Per-delegation token; equals the filename token and the expected `dev_round_id` |
| `kind` | Yes | `--kind` | `implement` or `fix` |
| `issue` | Yes | `--issue` | Normalized workflow-state key (Parent ID when bundled) |
| `branch` | Yes | `--branch` | Git branch (non-empty string) |
| `commit` | Yes | `--commit` | HEAD SHA after the commit, or the prior HEAD when no commit was needed |
| `baseline_lines` | implement | measured by writer | Additions plus deletions against the base branch at `commit`, omitting binary rows and render mirrors whose source changed in the same diff, floored at 1. Absent for `fix` |
| `validate` | Yes | `--validate` | `pass`, `no-verdict` or `FAILING: check1,check2`, a closed enumeration. With `--validate-run-dir`, `pass` needs a local run that passed or a `ci` record whose verdict is `pending`; with `ci`, it accepts the local edits and leaves required CI pending: the merge-group run proves the head where the record carries `ci-event=merge_group`, as every queue-only change's does, and a red one returns the change to its lane under [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) Recovery cycle. `no-verdict` needs a run that ended with that result (`--record` reads `verdict=no-verdict`); `--validate-record` follows the [foreground record rule](#foreground-validation-record); `FAILING` is accepted beside a run of any verdict, because it judges every gate of the round; a `fix` receipt's run must still belong to its round (see `validate_mode`). The check accepts `pass` and `no-verdict` and retries `FAILING` |
| `validate_mode` | Yes | read from `--validate-run-dir` or `--validate-record` | The mode `orch-runtime validate entry --record` reports for the run directory, or the `full` or `range` a [foreground validation record](#foreground-validation-record) states: `full`, the whole battery, which may execute scoped suites, `range`, a fix round's changes since its base, `docs`, a docs-only snapshot's declared text checks, or `ci`, completed local edits with required CI pending. Where the project sets `DEV_VALIDATE_SELECTION_CMD`, a `ci` run first runs that selector's scoped suites, so a `ci` record can also carry `FAILING` or `no-verdict`. Implement and fix receipts accept `ci` only at the current HEAD. The runner's `head` is the HEAD at validation start, before the workflow commits; its snapshot tree binds those pending contents to this receipt's committed `commit`, and the writer refuses changed contents as `ci-contents-mismatch`. This receipt is no CI pass: submit checks required pull-request CI, and its queue route proves required merge-group CI for queue-only work. `null` only beside a failing `validate` without completed evidence, which omits both flags; a `pass` or `no-verdict` without the flag is refused. The check echoes it and answers `invalid` for a missing key or any other value. A `fix` receipt names only a run or record that validated its committed tree, FAILING included, and whose HEAD contains its round record's `base_sha`, records that base as `validate-base-orphaned`, or contains that base's rewritten SHA in the worktree-private `kendex-rebase-map` (ordered hops per [`workflow-state.md`](workflow-state.md), `rebase_map` row), or whose tree is that base's own; the writer refuses any other run as `run-off-round`. A run directory whose start record names no tree, and a foreground record, prove their recorded HEAD's tree only while that HEAD is the worktree's HEAD and `git status --porcelain --untracked-files=all` reports nothing. A run the runtime started carries its mode on the round's admitted `validate` entry (`proof`), resolved from the project's declaration, and the check answers a `fix` receipt recording another mode `mode_mismatch`; a `fix` receipt whose run has no such entry (an ad-hoc run, or a foreground record) may record any mode but `ci`, and `ci` only on a round whose record carries `pr_open: true` or whose `pr-order` resolves `push-first`. Submit accepts a current-head `ci` receipt as pending, and in a project that forbids orch's validation runner reuses a current-head `full` pass from a foreground validation record; the runtime's proof reader (`orch-runtime read-proof --need submit`) decides whether any other pass proves the commit, per [`submit-pr.md`](../workflows/submit-pr.md) § 1.1 |
| `validate_time` | Yes | read from `--validate-run-dir` or `--validate-record` | The run's wall time as `orch-runtime validate entry --record` reports it, or as the writer derives it from a record's two times: `started_at` and `ended_at` in UTC, and `seconds` between them. A `no-verdict` run carries one too, since a host or timeout result also ends the run. `null` where no run is named or the run is unfinished, so only beside a failing `validate`; a time beside a `null` `validate_mode` is refused. The check echoes it, answers `invalid` for a missing key, a wrong type or seconds that are not the span, and records it per round |
| `validate_lanes` | Optional | read from `--validate-run-dir` or `--validate-record` | Comma-separated lane names from the command's [output contract](../references/artifact-checks.md#validation-command-output). Absent when unreported, when the selection is the start's preview (the output contract's Missing or malformed last line row), or when no run is named. The check echoes it for round storage |
| `validate_selection` | Optional | read from `--validate-run-dir` or `--validate-record` | `all`, `subset`, `battery` or `unreported` from `--record` or the record. Absent when no run is named. Changes neither `validate_mode` nor the verdict |
| `validate_class_base` | Optional | read from `--validate-run-dir` | The commit `--record` reports as `class-base`: a `range` request's base, whichever mode ran, or the branch merge base for scoped full execution. A scoped `ci` run carries it too: the round base, or the branch merge base for a full request or an orphaned base. A full run with this field covers the whole branch's battery only where its `validate_selection` is `battery`; the runtime's proof reader (`orch-runtime read-proof`) and the start's reuse decide whether submit reuses it. Absent for whole-branch validation and for a `ci` run that ran no command. The check echoes it, `null` when absent |
| `validate_note` | Optional | `--validate-note` | A free-text qualifier the enumeration cannot express, or `null`. Required beside `no-verdict`, where it names the host cause or timeout; the writer refuses a `no-verdict` without it as `required`, and the check answers one `invalid` |
| `qa_labels` | Optional | `--qa-label` (repeatable) | Applied QA labels; `[]` when none |
| `near_ceiling` | Optional | `--near-ceiling-base` | One `byte-ceiling` `near-ceiling` line per binary blob within reach of the byte ceiling, as the lane reports the branch at artifact time; `[]` when none. The writer runs the worktree's installed lane with `--base REF` and keeps its near-ceiling lines on exit 0 or 1; a repository with nothing at the lane path has no byte ceiling and records `[]`. An omitted `--near-ceiling-base`, a dangling link at or above the lane, a lane that is not executable, or a lane that exits otherwise records `null`, which means unknown, never none. A blob that first enters the warn band in work landed afterwards, including one the pre-push lane names on a rebased or squashed state, is not in the list, so the list is no completeness claim about the branch as pushed. The check echoes it, and the orchestrator stores it as workflow state's `near_ceiling` so the next round's brief plans Git LFS, an asset store or generation before a later commit meets the ceiling |
| `near_ceiling_error` | Optional | set by the writer | Why `near_ceiling` is `null`: `byte-ceiling exit N:` and the lane's first stderr line, `byte-ceiling not executable:` and the lane path, `byte-ceiling broken link:` and the dangling link above the lane, or `byte-ceiling not probed: no --near-ceiling-base`; `null` otherwise. The check echoes it, and `dev-start.md` § Store Near-Ceiling Lines names it in the round's report |
| `screenshots` | Optional | `--screenshot` (repeatable) | The round's captures as absolute paths, one per flag; the writer refuses a path that is not a readable file as `screenshot-unreadable`, and the key is absent where none is named. The check echoes it (`[]` where absent), and the acceptance's `accept-result {attachments}` attaches each to the item's summary comment |
| `summary_posted` | Optional | `--no-summary` sets `false` | `true` where the tracker is Linear and the acceptance posts `summary` to the item after the round's close; GitHub and ad-hoc rounds set `false`, and so does a recovered artifact, since recovery never verifies a post |
| `summary` | Optional | `--summary`, `--summary-file` or `--recovered-text` | The summary content, or `null`. Every single implement round embeds it, including a Linear round that also sets `summary_posted: true`, so a consumer can read its `### Proposed Rules` |
| `recovered_from` | Optional | `--recovered-text` sets `"transcript"` | `"transcript"` when `orch-runtime round --text recover` wrote the artifact from a stalled agent's transcript, with that report as `summary`; otherwise `null` |
| `bundled` | Optional | `--bundled` sets `true` | `true` for a bundled implement |
| `items` | Conditional | `--item N DECISION REASONING` | Per kind rules below |

`items[]` elements are `{n: number, decision: "Applied"|"Skipped"|"Blocked", reasoning: string}`, with `n` the review item's `#N` or the sub-issue index and `reasoning` non-empty, citing the decision id or rule when `Skipped`.

## Kind rules

| Case | `items` |
|------|---------|
| `implement`, single | May be empty: `items: []` |
| `implement`, `--bundled` | Non-empty, one entry per sub-issue result |
| `fix` | Non-empty, one entry per delegated review item, and `--expect-items`/`--expect-items-from-round` requires the set to match exactly |

## `validate` and its note

`validate` is a closed enumeration. `--validate-note` records what the enumeration cannot express. The dev skill's `dev-implement.md` § 5 owns the permitted correction and rerun routes and the notes they require. The note never relaxes `--validate`, which records the final run's verdict:

```bash
--validate "FAILING: cargo test" --validate-note "Test-only validation ceiling: the suite failed at 34m; the failed target passed alone under load"
```

`no-verdict` reports a timeout or an unavailable host check: neither a pass nor a failure. The validation command reserves exit 3 for the host result, as `orch-runtime validate entry --help` states. The round takes the route [dev-implement.md § 5](../../dev/workflows/dev-implement.md#5-validate) names, and `validate_note` names the cause. Only a `no-verdict` whose `validate_mode` is `ci` leaves its proof to required CI; any other is unproved.

The Apple gate reads `ORCH_APPLE_WORKFLOW`, default `.github/workflows/mac-run.yml`, and the space-separated `ORCH_APPLE_LABELS`, default `ios macos`, from the `--worktree` repository's settings. Where the base branch holds that configured workflow, a `pass` or `no-verdict` declares the item's labels, the delegation's `Labels:` entries or none, and the writer refuses it undeclared as `labels-undeclared`. An item the Apple gate names records its passing `mac run test` as one `validate_note` line, `mac run test: pass run=RUN_ID`, beside any other note text. The writer refuses that item's `pass` or `no-verdict` without the line, as `mac-run-missing`. A failed or absent run is `FAILING: mac run test`, which needs no line. The labels are never recorded, so every other receipt is unchanged.

The check echoes both. An empty or whitespace-only note is refused as `empty-text`.

## Foreground validation record

A project whose own policy runs its validation entry point in the foreground and forbids orch's validation runner names that run with `--validate-record FILE` in place of `--validate-run-dir`; the writer refuses the two together. FILE holds one `KEY=VALUE` per line: the mode, the HEAD the run started at, its UTC start and end, its exit status, and its lane selection with any lanes. `orch-runtime dev-return --text write --help` gives the grammar, and the writer refuses a record that names no head, no time or no exit status as `validate-record-missing`.

The writer reads the record into the fields a run directory fills, so the receipt has the same shape on either route. It derives the wall time from the two times and reads the verdict from the record's marker. An optional `verdict=no-verdict` carries that outcome with the same note and evidence requirements. Without the marker, exit 0 is `pass` and any other exit is `FAILING`. A `fix` receipt binds the record to its round as it binds a run directory's, by the tree `validate_mode` states. The record file stays where the project wrote it; the receipt does not copy its head or exit status.

## Writer refusals

`orch-runtime dev-return --text write` writes nothing on a refusal. It exits 2 with one `dev-return-write: KEY CAUSE` line on stderr; without `--text` the reply is `ok: false` with the key, exit 1.

| Key | Meaning |
|-----|---------|
| `invalid-id` | The issue or round id is empty, carries `..`, holds a character outside `A-Za-z0-9._-`, or a run directory's id does |
| `not-directory` | The worktree cannot be read as a directory |
| `required` | No branch, a commit that is not hex, a `no-verdict` with no note, an empty `--near-ceiling-base`, or not exactly one evidence source for a `pass` or `no-verdict` |
| `invalid-validate` | `--validate` is none of `pass`, `no-verdict` or `FAILING: ...` |
| `empty-text` | An empty or whitespace-only note or summary |
| `run-record-unreadable`, `timing-unreadable` | The run directory's records cannot be read, or its times are not their span |
| `validate-record-unreadable`, `validate-record-line`, `validate-record-missing`, `validate-record-value`, `validate-record-lanes`, `validate-record-time` | A foreground record cannot be read, holds a line outside its grammar, misses a required key, holds a value outside its grammar, pairs lanes and selection wrongly, or ends before it starts |
| `validate-disagrees` | `--validate` differs from the named run's verdict |
| `ci-contents-mismatch` | A `ci` pass whose run snapshot is not the commit's tree |
| `missing-items` | A `fix`, bundled or itemized receipt without unique item numbers, decisions and reasoning |
| `round-missing`, `round-json`, `round-mismatch`, `round-schema` | A `fix` receipt's round record is absent, is no JSON, carries another round, or fails [dev-round.md](dev-round.md)'s schema |
| `run-off-round` | A `fix` receipt's run did not validate its tree from its round, as `validate_mode` states |
| `run-headless`, `ancestry-unreadable`, `rebase-map-unreadable`, `git-failed` | A run with no recorded HEAD, or a git read the binding or the Apple gate needs gave no answer |
| `summary-conflict`, `missing-file` | More than one summary source, or a summary file that cannot be read |
| `screenshot-unreadable` | A `--screenshot` path that is not a readable file |
| `labels-undeclared`, `mac-run-missing` | The Apple gate above |
| `baseline-read`, `artifact-read` | The shared branch measurement, or a program it runs, gave no answer |
| `receipt-exists` | A failing receipt already stands at the path |
| `record-symlink`, `artifact-write`, `artifact-cleanup` | The receipt path is a symlink, the receipt could not be written, or its scratch file could not be removed |
