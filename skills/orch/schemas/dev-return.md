# Dev Return (Completion Artifact) Schema

The on-disk record a dev or QA agent writes at the end of an implement or fix delegation. Orch accepts a completion from it **independently of the live return message**.

Written **only** by `dev-return-write` — never hand-authored, never composed with a file-write tool. The writer builds the JSON with `jq` and writes it atomically; its `--help` is the flag reference. Validation gates live in `dev-artifact-check --help`; round-closure routing in [`../references/artifact-checks.md`](../references/artifact-checks.md).

Every `implement` receipt carries the branch's additions plus deletions at its commit as `baseline_lines`, with binary rows and mandated render mirrors omitted and a floor of 1. A render pairs off against the source it renders by the rule `branch-size-check` uses, so a source with a tracked render is counted once. The receipt value measures churn; it does not authorize a fix round. The issue's optional `**Expected delta**` line supplies the comparison in the size report; [dev-round.md § Declared cuts](dev-round.md#declared-cuts) defines chosen cuts.

## Identity: the round id

Each delegation stamps a unique token (`workflow-state new-round-id [ISSUE] dev_round_id`) and embeds it in the delegation. The artifact is bound to that token twice: its filename is `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json`, and it carries `"round_id": ROUND_ID` inside. `dev-artifact-check --round-id RID` resolves that exact path and requires the internal token to match.

Fix rounds have an input-side sibling bound by the same token, `tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` — the delegated item set the orchestrator persists at stamp time, checked against this artifact's `items[]` via `--expect-items-from-round`. Schema: [`dev-round.md`](dev-round.md).

`[ISSUE_ID]` is the workflow-state key where one exists, whose forms `workflow-state --help` § Keys enumerates; a bundled delegation uses the Parent ID. Ad-hoc work runs no workflow-state step and has no key: the orchestrator supplies an opaque id that names the artifact file alone, never an empty or free-form string. Both, and `[ROUND_ID]`, must match `^[A-Za-z0-9._-]+$` with no `..`.

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
  "validate_note": "Test-only validation ceiling: the suite failed at 34m; the failed target passed alone under load",
  "qa_labels": ["needs-review"],
  "near_ceiling": ["byte-ceiling: near-ceiling=crates/core/src/engine/deps.rs:189000:204800:92"],
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
| `validate` | Yes | `--validate` | `pass` or `FAILING: check1,check2` — a closed enumeration |
| `validate_mode` | Yes | `--validate-mode` | The mode the round's `dev-validate-run` recorded: `full`, the whole battery and the default, or `range`, a fix round's changes since its base. `dev-artifact-check` echoes it. Submit reuses only a `full` pass |
| `validate_note` | Optional | `--validate-note` | A free-text qualifier the enumeration cannot express, or `null` |
| `qa_labels` | Optional | `--qa-label` (repeatable) | Applied QA labels; `[]` when none |
| `near_ceiling` | Optional | `--near-ceiling-base` | One `byte-ceiling` `near-ceiling` line per file within reach of the byte ceiling, as the lane reports the branch AT ARTIFACT TIME; `[]` when none. The writer runs the worktree's installed lane with `--base REF` and keeps its near-ceiling lines on exit 0 or 1; a repository with nothing at the lane path has no byte ceiling and records `[]`. An omitted `--near-ceiling-base`, a dangling link at or above the lane, a lane that is not executable, or a lane that exits otherwise records `null`, which means unknown, never none. A file that first enters the warn band in work landed afterwards, including one the pre-push lane names on a rebased or squashed state, is not in the list, so the list is not a completeness claim about the branch as pushed. `dev-artifact-check` echoes it, and the orchestrator stores it as workflow state's `near_ceiling` so the next round's brief plans the split before a later commit meets the ceiling |
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

`validate` is a closed enumeration. `--validate-note` records what the enumeration cannot express — the test-only validation-ceiling re-run that the dev skill's `dev-implement.md` § 5 names, or a flake worth recording — and it never relaxes `--validate`. Outside that named ceiling a failing validation ends the round; it is never re-run into a pass:

```bash
--validate "FAILING: cargo test" --validate-note "Test-only validation ceiling: the suite failed at 34m; the failed target passed alone under load"
```

`dev-artifact-check` echoes both. An empty or whitespace-only note is rejected.
