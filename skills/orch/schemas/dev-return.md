# Dev Return (Completion Artifact) Schema

The on-disk record a dev or QA agent writes at the end of an implement or fix delegation. Orch accepts a completion from it **independently of the live return message**.

Written **only** by `dev-return-write` — never hand-authored, never composed with a file-write tool. The writer builds the JSON with `jq` and writes it atomically; its `--help` is the flag reference. Validation gates live in `dev-artifact-check --help`; round-closure routing in [`../references/artifact-checks.md`](../references/artifact-checks.md).

Every `implement` receipt carries the branch's additions plus deletions at its commit as `baseline_lines`, with binary rows and mandated render mirrors omitted and a floor of 1. The shared branch measurement pairs a render against the source it renders, so a source with a tracked render is counted once. The receipt value measures churn; it does not authorize a fix round. CI also reads this shared measurement to classify a change and choose its checks.

## Identity: the round id

Each delegation stamps a unique token (`workflow-state new-round-id [ISSUE] dev_round_id`) and embeds it in the delegation. The artifact is bound to that token twice: its filename is `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json`, and it carries `"round_id": ROUND_ID` inside. `dev-artifact-check --round-id RID` resolves that exact path and requires the internal token to match.

Fix rounds have an input-side sibling bound by the same token, `tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` — the delegated item set the orchestrator persists at stamp time, checked against this artifact's `items[]` via `--expect-items-from-round`. Schema: [`dev-round.md`](dev-round.md).

`[ISSUE_ID]` is the workflow-state key where one exists, whose forms `workflow-state --help` § Keys enumerates; a bundled delegation uses the Parent ID. An ad-hoc id is a `local-` key from `workflow-state new-local-key`, never an empty or free-form string. The command writes nothing, so ad-hoc work that runs no workflow-state step uses the key to name the artifact file alone. [`review.md` § 4](../workflows/review.md#4-present-and-fix) mints one for a review of a branch carrying no issue id and inits state under it. Both, and `[ROUND_ID]`, must match `^[A-Za-z0-9._-]+$` with no `..`.

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
| `baseline_lines` | implement | measured by writer | Additions plus deletions against the base branch at `commit`, omitting binary rows and render mirrors whose source changed in the same diff, floored at 1. **Absent for `fix`** |
| `validate` | Yes | `--validate` | `pass`, `no-verdict` or `FAILING: check1,check2` — a closed enumeration. With `--validate-run-dir`, `pass` needs a run that passed and `no-verdict` a run the timeout ended (`--record` reads `verdict=no-verdict`); with `--validate-record`, `pass` needs exit status 0, and `no-verdict` is refused because the record states no timeout; `FAILING` is accepted beside a run of any verdict, because it judges every gate of the round; a `fix` receipt's run must still belong to its round (see `validate_mode`). `dev-artifact-check` accepts `pass` and `no-verdict` and retries `FAILING` |
| `validate_mode` | Yes | read from `--validate-run-dir` or `--validate-record` | The mode `dev-validate-run --record` reports for the run directory, or the `full` or `range` a [foreground validation record](#foreground-validation-record) states: `full`, the full invocation, which may execute scoped suites, `range`, a fix round's changes since its base, or `ci`, a run the pull request CI on the pushed head validates. Implement and fix receipts accept `ci`. `null` only beside a failing `validate` with no run, which omits both flags; a `pass` or `no-verdict` without the flag is refused. `dev-artifact-check` echoes it and refuses a missing key or any other value. A `fix` receipt names only a run or record that started at a HEAD containing its round record's `base_sha`, recording that base as `validate-base-orphaned`, or containing that base's rewritten SHA in the worktree-private `kendex-rebase-map` (ordered hops per [`workflow-state.md`](workflow-state.md), `rebase_map` row), no earlier than its `delegated_at`, and records the mode its round runs, `range`, or `full` where the project sets no `DEV_VALIDATE_RANGE_CMD`, or `ci`: the writer refuses an earlier round's run as `run-off-round` or `run-before-round`, and `dev-artifact-check` refuses any other mode as `mode_mismatch`. Submit reuses only a `full` pass with no `validate_class_base`, or with `validate_selection` `battery` |
| `validate_time` | Yes | read from `--validate-run-dir` or `--validate-record` | The run's wall time as `dev-validate-run --record` reports it, or as the writer derives it from a record's two times: `started_at` and `ended_at` in UTC, and `seconds` between them. A `no-verdict` run carries one too, since the timeout's end is still an end. `null` where no run is named or the run is unfinished, so only beside a failing `validate`; a time beside a `null` `validate_mode` is refused. `dev-artifact-check` echoes it and refuses a missing key, a wrong type or seconds that are not the span; `dev-artifact-check` records it per round |
| `validate_lanes` | Optional | read from `--validate-run-dir` or `--validate-record` | Comma-separated lane names from the command's [output contract](../references/artifact-checks.md#validation-command-output). Absent when unreported or no run is named. `dev-artifact-check` echoes it for round storage |
| `validate_selection` | Optional | read from `--validate-run-dir` or `--validate-record` | `all`, `subset`, `battery` or `unreported` from `--record` or the record. Absent when no run is named. Does not change `validate_mode` or the verdict |
| `validate_class_base` | Optional | read from `--validate-run-dir` | The commit `--record` reports as `class-base`: a `range` request's base, whichever mode ran, or the branch merge base for scoped full execution. A full run with this field does not cover the whole branch's battery, so submit does not reuse it unless its `validate_selection` is `battery`. Absent for whole-branch validation and `ci`. `dev-artifact-check` echoes it, `null` when absent |
| `validate_note` | Optional | `--validate-note` | A free-text qualifier the enumeration cannot express, or `null`. Required beside `no-verdict`, where it names the scoped suites that passed; `dev-artifact-check` refuses a `no-verdict` without it |
| `qa_labels` | Optional | `--qa-label` (repeatable) | Applied QA labels; `[]` when none |
| `near_ceiling` | Optional | `--near-ceiling-base` | One `byte-ceiling` `near-ceiling` line per binary blob within reach of the byte ceiling, as the lane reports the branch AT ARTIFACT TIME; `[]` when none. The writer runs the worktree's installed lane with `--base REF` and keeps its near-ceiling lines on exit 0 or 1; a repository with nothing at the lane path has no byte ceiling and records `[]`. An omitted `--near-ceiling-base`, a dangling link at or above the lane, a lane that is not executable, or a lane that exits otherwise records `null`, which means unknown, never none. A binary blob that first enters the warn band in work landed afterwards, including one the pre-push lane names on a rebased or squashed state, is not in the list, so the list is not a completeness claim about the branch as pushed. `dev-artifact-check` echoes it, and the orchestrator stores it as workflow state's `near_ceiling` so the next round's brief plans Git LFS, an asset store or generation before a later commit meets the ceiling |
| `near_ceiling_error` | Optional | set by the writer | Why `near_ceiling` is `null`: `byte-ceiling exit N:` and the lane's first stderr line, `byte-ceiling not executable:` and the lane path, `byte-ceiling broken link:` and the dangling link above the lane, or `byte-ceiling not probed: no --near-ceiling-base`; `null` otherwise. `dev-artifact-check` echoes it, and `dev-start.md` § Store Near-Ceiling Lines names it in the round's report |
| `summary_posted` | Optional | `--no-summary` sets `false` | `true` only when the summary was posted to a tracker; GitHub and ad-hoc rounds set `false`, and so does a recovered artifact, since recovery never verifies a post |
| `summary` | Optional | `--summary`, `--summary-file` or `--recovered-text` | The summary content, or `null`. Every single implement round embeds it, including a Linear round that also sets `summary_posted: true`, so a consumer can read its `### Proposed Rules` |
| `recovered_from` | Optional | `--recovered-text` sets `"transcript"` | `"transcript"` when `round-recover` wrote the artifact from a stalled agent's transcript, with that report as `summary`; otherwise `null` |
| `bundled` | Optional | `--bundled` sets `true` | `true` for a bundled implement |
| `items` | Conditional | `--item N DECISION REASONING` | Per kind rules below |

`items[]` elements are `{n: number, decision: "Applied"|"Skipped"|"Blocked", reasoning: string}`, with `n` the review item's `#N` or the sub-issue index and `reasoning` non-empty — citing the decision id or rule when `Skipped`.

## Kind rules

| Case | `items` |
|------|---------|
| `implement`, single | May be empty → `items: []` |
| `implement`, `--bundled` | Non-empty — one entry per sub-issue result |
| `fix` | Non-empty — one entry per delegated review item, and `--expect-items`/`--expect-items-from-round` requires the set to match EXACTLY |

## `validate` and its note

`validate` is a closed enumeration. `--validate-note` records what the enumeration cannot express. The dev skill's `dev-implement.md` § 5 owns the permitted correction and rerun routes and the notes they require. The note never relaxes `--validate`, which records the final run's verdict:

```bash
--validate "FAILING: cargo test" --validate-note "Test-only validation ceiling: the suite failed at 34m; the failed target passed alone under load"
```

`no-verdict` is a battery the timeout cut off: neither a pass nor a failure. The round's result is then the scoped suites `dev-implement.md` § 5 names, listed in `validate_note`, and CI is the full record. Submit does not re-run a `no-verdict` of either mode, and a run of its own that ends `no-verdict` takes the same scoped-suite fallback.

Where the base branch holds the mac-run workflow, a `pass` or `no-verdict` declares the item's labels, the delegation's `Labels:` entries or none, and the writer refuses it undeclared as `labels-undeclared`. An item the Apple gate in `dev-return-write --help` names records its passing `mac run test` as one `validate_note` line, `mac run test: pass run=RUN_ID`, beside any other note text. The writer refuses that item's `pass` or `no-verdict` without the line, as `mac-run-missing`. A failed or absent run is `FAILING: mac run test`, which needs no line. The labels are never recorded, so every other receipt is unchanged.

`dev-artifact-check` echoes both. An empty or whitespace-only note is rejected.

## Foreground validation record

A project whose own policy runs its validation entry point in the foreground and forbids `dev-validate-run` names that run with `--validate-record FILE` in place of `--validate-run-dir`; the writer refuses the two together. FILE holds one `KEY=VALUE` per line: the mode, the HEAD the run started at, its UTC start and end, its exit status, and its lane selection with any lanes. `dev-return-write --help` gives the grammar, and the writer refuses a record that names no head, no time or no exit status.

The writer reads the record into the fields a run directory fills, so the receipt has the same shape on either route. It derives the wall time from the two times and the verdict from the exit status, `pass` for 0 and `FAILING` for any other. A `fix` receipt binds the record's head and start time to its round as it binds a run directory's. The record file stays where the project wrote it; the receipt does not copy its head or exit status.
