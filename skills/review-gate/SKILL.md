---
name: review-gate
description: "Org-wide PR review gate: one predicate answers 'is this exact head reviewed?' (review objects, trusted clean-analysis checks, comment-form passes, operator override), one writer posts it as a merge-blocking commit status, plus an offline decision-table selftest and a live replay harness. Load when wiring, adopting, tuning, or debugging a repo's review gate or its REVIEW_GATE_* settings."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "2.0.0"
---

# Review Gate

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

The gate answers ONE question: **has this exact PR head been reviewed?** It
posts that answer as a commit status the repo's branch rules require.

It does not check CI, re-run anything, or reason about jobs. Whether untested
code can reach the default branch is branch protection's job — see the
adoption precondition below.

## Decision table

| Verdict | Status | Meaning |
|---|---|---|
| `approved` | `success` | Evidence exists for this head; no standing objection; no unresolved threads. |
| `awaiting` | `pending` | No review evidence for this head yet. |
| `threads-open` | `pending` | Evidence exists, but review threads are unresolved. |
| `changes-requested` | `failure` | A reviewer objects. Red means objection — never a build failure. |
| (exit 2, no verdict) | *unchanged* | A read failed or config is invalid. Take NO action; retry next pass. |

## ADOPTION PRECONDITION — check this first

A repo must satisfy one, or untested code can merge and this engine will not
stop it:

1. **A merge queue** whose required contexts include the repo's test
   aggregate (recommended — the suite runs once, on the merged result).
2. **No held-back jobs** — every required check runs on every push.

The hazard: held-back jobs report as `skipped`, and GitHub counts skipped as
satisfied. Hold jobs back with no queue and a reviewed PR merges untested.
Proven live in the sandbox (`tests/e2e-sandbox.sh` scenario 11); that
scenario is the safety claim and must pass on every adopting repo.

## Evidence sources (`scripts/review-predicate.sh`)

Evidence for the CURRENT head is any of:

1. **Review object** at the exact head from a non-author, non-dismissed
   login — restricted to `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` when set,
   and to APPROVED reviews when `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE =
   "approved"`. An approval is never superseded by a later COMMENTED from the
   same reviewer; only a later CHANGES_REQUESTED withdraws it.
2. **Trusted clean-analysis check-run or commit status**
   (`REVIEW_GATE_TRUSTED_STATUS_CONTEXTS`) succeeding on this head — but a
   pass must prove analysis RAN: a success matching
   `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` (e.g. "rate limited") is
   NOT-EVIDENCE, never a failure. It is silence, which `awaiting` handles.
   On BOTH surfaces the NEWEST row/run per name decides (statuses by list
   order, check-runs by run id — vstack#1110): an older clean success never
   outlives its reviewer's newer pending/failed/skip-marked round.
3. **Comment-form clean pass** (`REVIEW_GATE_COMMENT_REVIEWERS`): an issue
   comment by a trusted bot login — never the PR author, even if configured —
   binding the evidence to this head's sha (floor
   `REVIEW_GATE_SHA_PREFIX_FLOOR`).
4. **Operator override** (`REVIEW_GATE_OVERRIDE_CONTEXT`, legacy name
   `REVIEW_GATE_OUTAGE_CONTEXT`): a trusted operator's status carrying a
   NON-EMPTY reason, which is enforced and surfaced in the gate detail.
   Substitutes for MISSING evidence ONLY — it can never override a
   changes-requested or an unresolved thread, so the internal review must fix
   findings and resolve threads first, then attest.

With `REVIEW_GATE_CARRY_FORWARD` (off by default), evidence at an ancestor
carries to head when the delta is provably in a class review would not
re-examine — docs-only, comment-only, identical tree. Never a waiver: real
evidence must exist, code changes always require fresh evidence, and the
fail-closed terms still apply.

Changes-requested and unresolved threads always fail closed. Every evidence
read fails LOUD (exit 2, no verdict) — a transient API error must never flip
a healthy PR's state; reads retry in-process up to `REVIEW_GATE_API_ATTEMPTS`
(default 1), and a zero-byte producer is a failed read, not an empty page
set. Over 100 review threads reports overflow and fails closed to
`threads-open`.

**Trust model.** Trust keys on names only GitHub controls: the author login
of a review or comment, or the exact check/status context on repos where
every publisher is trusted. A comment body never establishes trust — it is
read only to BIND evidence to a commit, so a stale comment cannot vouch for a
later push. Where PR workflows hold `statuses:write`, the opt-in
`REVIEW_GATE_STATUS_PUBLISHER_REJECT` list rejects statuses minted by a
forgeable creator (typically `github-actions[bot]`) on both the
trusted-context and override reads. Statuses are read from the per-commit
statuses LIST endpoint, where every real publisher — GitHub Apps included —
carries a creator login; while the reject list is configured, a status with
no creator login is an anomaly and is not evidence (with the list empty, the
default, the filter is off entirely).

## The writer (`scripts/review-writer.sh`)

One workflow, defined on the default branch, is the only thing that writes
the gate status. It evaluates the predicate and converges the status —
nothing else.

- **Converge-all on every leg.** Every invocation converges EVERY open PR,
  so a run evicted from the concurrency group strands nothing (8 evictions
  observed in one sandbox replay, zero stranded).
- **Write ordering.** Before any `success` post it re-reads the status and
  defers when any gate entry was created at/after this run's evaluation
  instant — a newer run's state AND description (which carries the audit
  detail) both stand; a failed re-read defers too. Downward posts never
  defer.
- **Idempotent.** When the current entry already matches state + description
  it no-ops, so idle cron ticks append nothing.
- **Forks need no special case** — every leg holds a write-capable
  default-branch token. The one exception is `pull_request_review` on a fork
  PR, whose token GitHub downgrades to read-only: that run exits green as a
  no-op and the cron floor converges it.
- **`pull_request_target` safety**: the job never executes PR-controlled
  code. Every checkout pins the default branch with credentials dropped.

## Scripts

```bash
# verdict for one head (env: GH_REPO, PR_NUMBER, HEAD_SHA[, PR_AUTHOR])
.agents/skills/review-gate/scripts/review-predicate.sh

# converge every open PR's gate status (env: GH_REPO)
.agents/skills/review-gate/scripts/review-writer.sh

# offline decision-table selftest (~1s, no network), run from the repo root
.agents/skills/review-gate/scripts/review-predicate-selftest.sh

# live replay against a throwaway sandbox repo — before any engine change
E2E_REPO=<owner>/<repo> .agents/skills/review-gate/tests/e2e-sandbox.sh
```

## Operations

**Reviewers are down / nothing is reviewing.** Run the internal review loop:
fix findings, resolve every thread, then post the override status with a real
reason. It cannot bypass an objection or an open thread — that is the point.

**A PR that repairs the gate itself.** The writer always runs the merged
engine, so a broken predicate cannot open its own repair PR's gate. Merge it
with the ruleset's bypass actor (every fleet repo has one configured) and say
so in the commit message.

**A settings-change PR** is judged by the OLD config — a PR adding a trusted
login cannot have its own gate honor it. Merge via normal review or the
bypass actor.

## Settings

Every per-repo value is a `REVIEW_GATE_*` key (env > `vstack.settings.toml` >
default). Full table and the security reasoning:
[references/settings.md](references/settings.md).

## Selftest — the engine's portable proof

`scripts/review-predicate-selftest.sh` pins the decision table offline: a
`gh` shim answers from fixtures and applies `--jq` through real jq, so the
real predicate runs unmodified. Every case ending `approved` is paired with a
near-miss that must not. Two layers: a mechanism layer with forced
configurations, and a configured layer that re-derives the battery from the
invoking repo's own resolved settings — so a repo trusting a different bot
tests its own trust list.

Every consumer's CI must run it as a deliberately **ungated** job (own job,
no `needs`): a broken predicate approves nothing, so a selftest behind the
gate could never run when it matters.

## Adoption

Copy `templates/review-gate-writer.yml` into `.github/workflows/` (repo-owned
after copy; `vstack refresh` does not sync workflow YAML), set the repo's
`REVIEW_GATE_*` values, add the ungated selftest job, and require the gate
context in the ruleset alongside the test aggregate. Full wiring:
[references/adoption.md](references/adoption.md). An adoption PR deletes the
local machinery it supersedes in the same PR — a redesign removes what it
replaces, never leaves it dormant.
