# Dev Return (Completion Artifact) Schema

The durable on-disk record a dev/QA agent writes at the end of an implement or fix
delegation. It is the deterministic completion signal orch reads to accept a
dev/QA completion **independently of the live return message**, which can be lost
when a long `tools/validate`-class command exceeds the harness tool timeout
mid-tail and ends the turn (vstack#770).

## Deterministic identity: the round id (vstack#776)

Each delegation stamps a unique **round token** (`workflow-state new-round-id
[ISSUE] dev_round_id`) and embeds it in the delegation (`Round ID:` line). The
artifact is bound to that token two ways:

- its filename is `[WORKTREE_PATH]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json`, and
- it carries `"round_id": ROUND_ID` inside.

`dev-artifact-check` resolves that exact path and requires the internal `round_id`
to equal the expected token. This clock-independent identity replaces the earlier
`mtime >= dev_delegated_at` freshness heuristic, which proved only *when* bytes
were written — not *which* delegation wrote them, so a same-second re-stamp, a
timed-out old-round agent rewriting late, a bundle group-A receipt consumed by
group-B, or a cross-round `ci-fix` receipt could all be mis-accepted at the single
reused path. `dev_delegated_at` remains, now solely as the watchdog deadline.

`[ISSUE_ID]` is the normalized workflow-state key — `issue-N` for GitHub,
`PROJ-123` for Linear; for a **bundled** delegation it is the Parent ID. It (and
`[ROUND_ID]`) must match the path-safe grammar `^[A-Za-z0-9._-]+$` with no `..` —
issue-less/ad-hoc work must use an orchestrator-supplied opaque id in that grammar,
never an empty or free-form string.

## Written by `dev-return-write` — never hand-authored

Do not compose this JSON by hand and do not write it with a file-write tool. Run
the writer, which builds the JSON deterministically with `jq` and writes it
atomically (temp file + `mv`, so a concurrent checker never sees a partial
artifact):

```bash
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind implement|fix \
  --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [HEAD_SHA_AFTER_COMMIT] \
  --validate [pass|"FAILING: c1,c2"] [--qa-label LABEL]... [--bundled] [--no-summary] \
  [--summary-file PATH] [--item N DECISION REASONING]...
```

It is a sanctioned single-command invocation (harness-safe: one command with
explicit arguments, no shell redirection in the agent's own command). It writes
the artifact and prints its absolute path. Keep `--item` reasoning plain text (no
backticks) so the command stays classifier-safe under Codex `approval=never`.

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
  "qa_labels": ["needs-review"],
  "summary_posted": true,
  "summary": null,
  "bundled": false,
  "items": [
    { "n": 1, "decision": "Applied", "reasoning": "Fixed nil deref in empty buffer" }
  ]
}
```

## Fields

| Field | Required | Writer flag | Description |
|-------|----------|-------------|-------------|
| `schema_version` | Yes | (constant `1`) | Artifact schema version (number) |
| `round_id` | Yes | `--round-id` | Per-delegation token; must equal the filename token and the expected `dev_round_id` |
| `kind` | Yes | `--kind` | `"implement"` or `"fix"` |
| `issue` | Yes | `--issue` | Normalized workflow-state key (Parent ID when bundled); grammar `^[A-Za-z0-9._-]+$`, no `..` |
| `branch` | Yes | `--branch` | Git branch (non-empty string) |
| `commit` | Yes | `--commit` | HEAD SHA after the commit (prior HEAD if no commit was needed) |
| `validate` | Yes | `--validate` | `"pass"` or `"FAILING: check1,check2"` |
| `qa_labels` | Optional | `--qa-label` (repeatable) | Applied QA labels; `[]` when none (implement only) |
| `summary_posted` | Optional | `--no-summary` sets `false` | `true` only when the § 9.1 summary was posted to a tracker (Linear); GitHub/ad-hoc rounds set `false` |
| `summary` | Optional | `--summary-file PATH` | The completion-summary CONTENT, or `null`. Carries the summary for GitHub/ad-hoc rounds (returned to the orchestrator, not posted) so a lost return is recoverable |
| `bundled` | Optional | `--bundled` sets `true` | `true` for a bundled implement, else `false` |
| `items` | Conditional | `--item N DECISION REASONING` (repeatable) | See kind rules |

## Kind rules

| Case | `items` |
|------|---------|
| `implement`, single (no `--bundled`) | May be empty → `items: []` |
| `implement`, `--bundled` | Non-empty — one entry per sub-issue result |
| `fix` | Non-empty — one entry per delegated review item |

`dev-return-write` **rejects** (exit 2) a `fix` or `--bundled` invocation with no
`--item`, an empty `--item` REASONING, an out-of-set DECISION, a non-integer `N`,
or an `--issue`/`--round-id` outside the path-safe grammar.

## `items[]` element shape

| Field | Type | Description |
|-------|------|-------------|
| `n` | number | Item number (the review item's `#N` / sub-issue index) |
| `decision` | string | One of `Applied`, `Skipped`, `Blocked` |
| `reasoning` | string | Non-empty rationale (cite `DXXX` or a rule when `Skipped`) |

## Validated by `dev-artifact-check`

Orch validates the artifact deterministically with
`.agents/skills/orch/scripts/dev-artifact-check` (round mode:
`--worktree WT --issue ISSUE --round-id RID [--expect-items N,N,...]`). It prints
`{ok, path, reason}`; the gates are ordered and the first failure wins:

| Order | reason | Meaning |
|-------|--------|---------|
| 1 | `missing` | No artifact at the resolved round-scoped path |
| 2 | `invalid` | Internal `round_id` != expected, OR not parseable JSON, OR a required field wrong-typed/empty: `kind` ∈ implement\|fix; `issue`/`branch`/`commit`/`validate` non-empty **strings**; `round_id` non-empty string; `schema_version` a number |
| 3 | `incomplete` | `items[]` fails the applicable rule (below) |
| — | `valid` | All gates pass |

**Items rule:**
- With `--expect-items N,N,...` (fix rounds — the orchestrator passes the delegated
  item numbers): `items[]` must cover **exactly** that set — each expected `n`
  present once, no unknown or duplicate `n`, every `decision ∈ {Applied,Skipped,
  Blocked}`, every `reasoning` non-empty. A 1-item artifact cannot satisfy a
  10-item delegation.
- Without `--expect-items` (kind `fix` OR `bundled: true`): `items[]` must be a
  non-empty array of well-formed elements. Bundled sub-issue *completeness* is
  covered by the orchestrator's Linear `validate-completion --include-children-of`
  tracker check (B), not by the artifact.
- kind `implement` without `bundled` allows `items: []`.

The mtime/freshness gate is gone — identity is by round id (see above), so there
is no `stale` reason. A fresh **valid** artifact for the current round lets orch
accept a completion whose live return message was lost, without re-delegation. The
artifact proves the agent finished its tail; git/tracker corroboration and
exact-commit binding (`.commit == git rev-parse HEAD`) stay in the orch acceptance
decision table (`dev-start.md` § 3 / `dev-fix.md`).
