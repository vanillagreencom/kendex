# Dev Return (Completion Artifact) Schema

The durable on-disk record a dev/QA agent writes at the end of an implement, fix,
or analysis delegation. It is the deterministic completion signal orch reads to
accept a dev/QA completion **independently of the live return message**, which is
routinely absent when a long `tools/validate`-class command outlasts the agent's
turn (vstack#770, vstack#818).

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
  --validate [pass|"FAILING: c1,c2"] [--validate-note TEXT] [--qa-label LABEL]... \
  [--bundled] [--no-summary] [--summary TEXT | --summary-file PATH] [--item N DECISION REASONING]...
```

For a **read-only analysis round** (investigate + recommend, explicitly no
implementation — see § Analysis rounds below):

```bash
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind analysis \
  --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --branch [BRANCH] \
  --summary [RECOMMENDATION_TEXT] [--qa-label LABEL]... [--no-summary]
```

or, when the recommendation already lives in a file:

```bash
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind analysis \
  --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] --branch [BRANCH] \
  --summary-file [RECOMMENDATION_FILE] [--qa-label LABEL]... [--no-summary]
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

## Fields

| Field | Required | Writer flag | Description |
|-------|----------|-------------|-------------|
| `schema_version` | Yes | (constant `1`) | Artifact schema version (number) |
| `round_id` | Yes | `--round-id` | Per-delegation token; must equal the filename token and the expected `dev_round_id` |
| `kind` | Yes | `--kind` | `"implement"`, `"fix"`, or `"analysis"` |
| `issue` | Yes | `--issue` | Normalized workflow-state key (Parent ID when bundled); grammar `^[A-Za-z0-9._-]+$`, no `..` |
| `branch` | Yes | `--branch` | Git branch (non-empty string) |
| `commit` | implement/fix only | `--commit` | HEAD SHA after the commit (prior HEAD if no commit was needed). **Forbidden for `analysis`** — the key must be absent |
| `validate` | implement/fix only | `--validate` | `"pass"` or `"FAILING: check1,check2"` — strictly enumerated, so it stays machine-checkable. **Forbidden for `analysis`** — the key must be absent |
| `validate_note` | Optional (implement/fix) | `--validate-note TEXT` | Free-text qualifier the enumeration cannot express, or `null`. **Forbidden for `analysis`** — the key must be absent. See below |
| `qa_labels` | Optional | `--qa-label` (repeatable) | Applied QA labels; `[]` when none (implement only) |
| `summary_posted` | Optional | `--no-summary` sets `false` | `true` only when the § 9.1 summary was posted to a tracker (Linear); GitHub/ad-hoc rounds set `false` |
| `summary` | Optional (required for `analysis`) | `--summary TEXT` or `--summary-file PATH` (mutually exclusive) | The completion-summary CONTENT, or `null`. Carries the summary for GitHub/ad-hoc rounds (returned to the orchestrator, not posted) so a lost return is recoverable. For `analysis` it carries the recommendation/evidence — the round's deliverable — and must be non-empty |
| `bundled` | Optional | `--bundled` sets `true` | `true` for a bundled implement, else `false` |
| `items` | Conditional | `--item N DECISION REASONING` (repeatable) | See kind rules |

## Recording a qualified validation result

`validate` is deliberately a closed enumeration — orch gates on it, so it must
stay machine-checkable. But a real run is not always cleanly one or the other: a
lane can fail once and pass on re-run over the identical diff, which is worth
investigating and worth recording. Without somewhere to put that, the artifact
says a bare `pass` and the caveat is lost from the record orch treats as
authoritative, surviving only if the agent happens to mention it
conversationally (vstack#884).

`--validate-note` is that place. It never relaxes `--validate`:

```bash
--validate pass \
--validate-note "80/80 on re-run; first run flaked on Rust Tests (release), same git_diff_hash"
```

`dev-artifact-check` echoes both `validate` and `validate_note` in its output, so
the note reaches the orchestrator that accepts the completion rather than only
the file. An empty or whitespace-only note is rejected (exit 2) — it would look
like a recorded caveat while carrying nothing.

## Kind rules

| Case | `items` |
|------|---------|
| `implement`, single (no `--bundled`) | May be empty → `items: []` |
| `implement`, `--bundled` | Non-empty — one entry per sub-issue result |
| `fix` | Non-empty — one entry per delegated review item |
| `analysis` | Always `[]` — `--item` (and `--bundled`) are rejected |

`dev-return-write` **rejects** (exit 2) a `fix` or `--bundled` invocation with no
`--item`, an empty `--item` REASONING, an out-of-set DECISION, a non-integer `N`,
or an `--issue`/`--round-id` outside the path-safe grammar.

## Analysis rounds (vstack#952)

`--kind analysis` is the truthful spelling for a **read-only round**: the agent
was delegated to investigate and recommend (e.g. re-derive an issue's premise and
propose implement / close-with-reasoning / re-scope), explicitly **not** to
implement. Such a round legitimately produces no commit and runs no
`tools/validate`, so:

- `--commit`, `--validate`, and `--validate-note` are **rejected** (exit 2, with
  an error naming why) — supplying one would assert a validation outcome that did
  not occur, which is exactly the property this schema exists to make impossible.
  The written artifact **omits those keys entirely**, and `dev-artifact-check`
  treats their presence on an analysis artifact as `invalid`.
- `--item` and `--bundled` are rejected — nothing was applied.
- Exactly one of `--summary TEXT` (inline) or `--summary-file PATH` is
  **required**: the recommendation and its evidence are the round's deliverable,
  and the artifact must carry them durably (across a lost return message or
  compaction), not just conversationally. The inline form exists because a
  harness can refuse the file write `--summary-file` depends on (vstack#1236) —
  a short recommendation does not need a file, and a blocked write must not
  leave a false `fix` receipt as the only exit.
- Round-id identity is identical to the other kinds — same filename token, same
  internal `round_id` binding.

Never force `--kind implement` or `--kind fix` onto an analysis round, and never
skip the artifact to stay honest — `analysis` is the honest spelling.

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
`{ok, path, reason, warning}`; the gates are ordered and the first failure wins:

| Order | reason | Meaning |
|-------|--------|---------|
| 1 | `missing` | No artifact at the resolved round-scoped path |
| 2 | `invalid` | Internal `round_id` != expected, OR not parseable JSON, OR a required field wrong-typed/empty: `kind` ∈ implement\|fix\|analysis; `issue`/`branch` non-empty **strings**; `round_id` non-empty string; `schema_version` a number. implement/fix additionally require `commit`/`validate` non-empty strings; **analysis requires the inverse** — no `commit`, `validate`, or `validate_note` key present at all |
| 3 | `commit_unresolvable` | The artifact's `commit` names no object in the worktree's git repo (vstack#994) — e.g. a hand-reconstructed SHA with a fabricated tail. Round mode only; skipped when the worktree is not a git repo, and always in `--file` mode (no repo to check against) |
| 4 | `incomplete` | `items[]` fails the applicable rule (below), or an `analysis` artifact's `summary` is not a non-empty string |
| — | `valid` | All gates pass |

**`hint` (fatal-path diagnosis):** null except for the `--expect-items`
count-vs-set misuse signature (a bare integer N > 1 while the artifact's item
numbers are exactly 1..N) — free text naming the caller's usage error so an
`incomplete` verdict is not misread as the dev agent skipping items. `warning`
never carries it.

**`warning: "commit_unreachable"` (non-fatal, vstack#994):** the `commit`
resolves as a commit object but is not an ancestor of the current `HEAD` — the
signature of a receipt orphaned by a later rebase. `ok` stays `true` and
`reason` stays `valid`: a legitimate rebase orphans the SHAs of every
previously accepted round, so this is a signal for the orchestrator to weigh,
not a failure. `warning` is `null` in every other case.

**Items rule:**
- With `--expect-items N,N,...` (fix rounds — the orchestrator passes the delegated
  item numbers): `items[]` must cover **exactly** that set — each expected `n`
  present once, no unknown or duplicate `n`, every `decision ∈ {Applied,Skipped,
  Blocked}`, every `reasoning` non-empty. A 1-item artifact cannot satisfy a
  10-item delegation.
- Without `--expect-items` (kind `fix` OR `bundled: true`): `items[]` must be a
  non-empty array of well-formed elements. Bundled sub-issue *completeness* is
  covered by the orchestrator's Linear `validate-completion --include-children-of`
  tracker check (B), not by the artifact. (Bundled delegation exists only for
  explicit single-PR bundles — `(one PR)` title marker; a container's child is
  a plain single delegation that validates alone.)
- kind `implement` without `bundled` allows `items: []`.
- kind `analysis` always has `items: []`; its completeness gate is the `summary`
  (non-empty string — the recommendation), not items.

The mtime/freshness gate is gone — identity is by round id (see above), so there
is no `stale` reason. A fresh **valid** artifact for the current round lets orch
accept a completion whose live return message was lost, without re-delegation. The
artifact proves the agent finished its tail, and (vstack#994) that its `commit`
names a real object in the worktree's repo; tracker corroboration and
exact-commit binding (`.commit == git rev-parse HEAD`) stay in the orch acceptance
decision table (`dev-start.md` § 3 / `dev-fix.md`). An `analysis` artifact has no
`commit`, so its round has no exact-commit binding and no validate gate — the
orchestrator instead expects `HEAD` unchanged, reads the `summary`
recommendation, and decides the next step (see the analysis rule in those
tables).
