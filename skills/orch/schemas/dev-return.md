# Dev Return (Completion Artifact) Schema

The durable on-disk record a dev or QA agent writes at the end of an implement, fix, or analysis delegation. Orch accepts a completion from it **independently of the live return message**, which is routinely absent when a long validation outlasts the agent's turn.

Written **only** by `dev-return-write` — never hand-authored, never composed with a file-write tool. The writer builds the JSON with `jq` and writes it atomically, and its `--help` is the flag reference. Validation gates live in [`../references/artifact-checks.md`](../references/artifact-checks.md).

## Identity: the round id

Each delegation stamps a unique token (`workflow-state new-round-id [ISSUE] dev_round_id`) and embeds it in the delegation. The artifact is bound to that token twice: its filename is `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json`, and it carries `"round_id": ROUND_ID` inside. `dev-artifact-check --round-id RID` resolves that exact path and requires the internal token to match, so identity is clock-independent — a same-second re-stamp, a timed-out old-round agent writing late, a bundle group-A receipt read for group-B, and a cross-round `ci-fix` receipt are all unmatchable.

Fix rounds have an input-side sibling bound by the same token, `tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` — the delegated item set the orchestrator persists at stamp time, checked against this artifact's `items[]` via `--expect-items-from-round`. Schema: [`dev-round.md`](dev-round.md).

`[ISSUE_ID]` is the normalized workflow-state key (`issue-N` for GitHub, `PROJ-123` for Linear; the Parent ID for a bundled delegation). It and `[ROUND_ID]` must match `^[A-Za-z0-9._-]+$` with no `..`, since they form the filename — ad-hoc work uses an orchestrator-supplied opaque id in that grammar, never an empty or free-form string.

## Schema

```json
{
  "schema_version": 1,
  "round_id": "1769600000123456789-1837",
  "kind": "implement",
  "issue": "PROJ-123",
  "branch": "user/proj-123",
  "commit": "abc123f",
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
| `kind` | Yes | `--kind` | `implement`, `fix`, or `analysis` |
| `issue` | Yes | `--issue` | Normalized workflow-state key (Parent ID when bundled) |
| `branch` | Yes | `--branch` | Git branch (non-empty string) |
| `commit` | implement/fix | `--commit` | HEAD SHA after the commit, or the prior HEAD when no commit was needed. **Absent for `analysis`** |
| `validate` | implement/fix | `--validate` | `pass` or `FAILING: check1,check2` — a closed enumeration, so orch can gate on it. **Absent for `analysis`** |
| `validate_note` | Optional | `--validate-note` | A free-text qualifier the enumeration cannot express, or `null`. **Absent for `analysis`** |
| `qa_labels` | Optional | `--qa-label` (repeatable) | Applied QA labels; `[]` when none |
| `summary_posted` | Optional | `--no-summary` sets `false` | `true` only when the summary was posted to a tracker; GitHub and ad-hoc rounds set `false` |
| `summary` | Required for `analysis` | `--summary` or `--summary-file` | The summary content, or `null`. Carries the summary for rounds that post nowhere, so a lost return is recoverable; for `analysis` it is the recommendation and its evidence, and must be non-empty |
| `bundled` | Optional | `--bundled` sets `true` | `true` for a bundled implement |
| `items` | Conditional | `--item N DECISION REASONING` | Per kind rules below |

`items[]` elements are `{n: number, decision: "Applied"|"Skipped"|"Blocked", reasoning: string}`, with `n` the review item's `#N` or the sub-issue index and `reasoning` non-empty — citing the decision id or rule when `Skipped`.

## Kind rules

| Case | `items` |
|------|---------|
| `implement`, single | May be empty → `items: []` |
| `implement`, `--bundled` | Non-empty — one entry per sub-issue result |
| `fix` | Non-empty — one entry per delegated review item, and `--expect-items`/`--expect-items-from-round` requires the set to match EXACTLY |
| `analysis` | Always `[]` — `--item` and `--bundled` are rejected |

## `validate` and its note

`validate` is a closed enumeration because orch gates on it. `--validate-note` records what the enumeration cannot express — e.g. a lane that failed once and passed on re-run over the identical diff — and it never relaxes `--validate`:

```bash
--validate pass --validate-note "80/80 on re-run; first run flaked on Rust Tests (release), same git_diff_hash"
```

`dev-artifact-check` echoes both, so the caveat reaches the orchestrator that accepts the completion rather than only the file. An empty or whitespace-only note is rejected — it would look like a recorded caveat while carrying nothing.

## Analysis rounds

`--kind analysis` is the truthful spelling for a **read-only round**: the agent was delegated to investigate and recommend, explicitly not to implement. Such a round produces no commit and runs no validation, so `--commit`, `--validate`, `--validate-note`, `--item`, and `--bundled` are all rejected and the artifact omits those keys entirely: a validation outcome that did not occur is unrepresentable, and `dev-artifact-check` treats their presence as `invalid`.

Exactly one of `--summary TEXT` or `--summary-file PATH` is required — the recommendation is the round's deliverable and must survive a lost return message. The inline form exists because a harness can refuse the file write; a blocked write must not leave a false `fix` receipt as the only exit.

Never force `implement` or `fix` onto an analysis round, and never skip the artifact to stay honest.
