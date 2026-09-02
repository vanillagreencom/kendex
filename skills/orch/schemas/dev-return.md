# Dev Return (Completion Artifact) Schema

The on-disk record a dev or QA agent writes at the end of an implement or fix delegation. Orch accepts a completion from it **independently of the live return message**.

Written **only** by `dev-return-write` — never hand-authored, never composed with a file-write tool. The writer builds the JSON with `jq` and writes it atomically; its `--help` is the flag reference. Validation gates live in `dev-artifact-check --help`; round-closure routing in [`../references/artifact-checks.md`](../references/artifact-checks.md).

Every `implement` receipt carries the branch's additions plus deletions at its commit as `baseline_lines`, with binary rows omitted and a floor of 1. When the round-mode receipt is accepted, `dev-artifact-check` records that value in workflow state only if `pr.baseline_lines` is null. The writer never changes workflow state.

## Identity: the round id

Each delegation stamps a unique token (`workflow-state new-round-id [ISSUE] dev_round_id`) and embeds it in the delegation. The artifact is bound to that token twice: its filename is `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json`, and it carries `"round_id": ROUND_ID` inside. `dev-artifact-check --round-id RID` resolves that exact path and requires the internal token to match.

Fix rounds have an input-side sibling bound by the same token, `tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` — the delegated item set the orchestrator persists at stamp time, checked against this artifact's `items[]` via `--expect-items-from-round`. Schema: [`dev-round.md`](dev-round.md).

`[ISSUE_ID]` is the normalized workflow-state key (`issue-N` for GitHub, `PROJ-123` for Linear; the Parent ID for a bundled delegation). It and `[ROUND_ID]` must match `^[A-Za-z0-9._-]+$` with no `..` — ad-hoc work uses an orchestrator-supplied opaque id in that grammar, never an empty or free-form string.

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
  "validate": "pass",
  "validate_note": "80/80 on re-run; first run flaked on Rust Tests (release), same git_diff_hash",
  "qa_labels": ["needs-review"],
  "summary_posted": true,
  "summary": null,
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
| `baseline_lines` | implement | measured by writer | Additions plus deletions against the base branch at `commit`, omitting binary rows and floored at 1. Round-mode acceptance writes the first value to workflow state. **Absent for `fix`** |
| `validate` | Yes | `--validate` | `pass` or `FAILING: check1,check2` — a closed enumeration |
| `validate_note` | Optional | `--validate-note` | A free-text qualifier the enumeration cannot express, or `null` |
| `qa_labels` | Optional | `--qa-label` (repeatable) | Applied QA labels; `[]` when none |
| `summary_posted` | Optional | `--no-summary` sets `false` | `true` only when the summary was posted to a tracker; GitHub and ad-hoc rounds set `false` |
| `summary` | Optional | `--summary` or `--summary-file` | The summary content, or `null`. Carries the summary for rounds that post nowhere |
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

`validate` is a closed enumeration. `--validate-note` records what the enumeration cannot express — e.g. a lane that failed once and passed on re-run over the identical diff — and it never relaxes `--validate`:

```bash
--validate pass --validate-note "80/80 on re-run; first run flaked on Rust Tests (release), same git_diff_hash"
```

`dev-artifact-check` echoes both. An empty or whitespace-only note is rejected.
