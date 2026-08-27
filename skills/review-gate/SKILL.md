---
name: review-gate
description: "Load to wire, adopt, tune, or debug a repo's review gate or its REVIEW_GATE_* settings."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.0.0"
tags: [review]
---

# Review Gate

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

The gate answers ONE question: **has this exact PR head been reviewed?** It
posts that answer as a commit status the repo's branch rules require. It does
not check CI, re-run anything, or reason about jobs.

Two greens do NOT mean a review happened. Under `REVIEW_GATE_MODE = "off"`
the predicate evaluates no evidence and attests only that the repo disabled
the gate; and merge-group statuses never read the mode, posting green as
"merge-queue entry: post-approval by construction". Both:
[references/settings.md](references/settings.md) § `REVIEW_GATE_MODE`.

## Decision table

| Verdict | Status | Meaning |
|---|---|---|
| `approved` | `success` | Evidence exists for this head; no standing objection; no unresolved threads. Under `REVIEW_GATE_MODE = "off"` the predicate evaluates NO term — success there means only "gate disabled", stated in the status description. |
| `awaiting` | `pending` | No review evidence for this head yet. |
| `threads-open` | `pending` | Evidence exists, but review threads are unresolved. |
| `changes-requested` | `failure` | A reviewer objects. Red means objection — never a build failure. |
| (exit 2, no verdict) | *unchanged* | A read failed or config is invalid. Take NO action; retry next pass. |

## ADOPTION PRECONDITION — check this first

A repo must satisfy one of these: **a merge queue** whose required contexts
include the test aggregate (recommended), or **no held-back jobs** (held-back
jobs report `skipped`, which GitHub counts as satisfied). Wiring:
[references/adoption.md](references/adoption.md) § The precondition.

## Evidence sources (`.agents/skills/review-gate/scripts/review-predicate.sh`)

Evidence for the CURRENT head is any of:

1. **Review object** at the exact head from a non-author, non-dismissed
   login — restricted to `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` when set,
   and to APPROVED reviews when `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE =
   "approved"`. An approval is never superseded by a later COMMENTED from the
   same reviewer; only a later CHANGES_REQUESTED withdraws it. A row whose
   body's first line (after trimming leading whitespace and markdown quote
   markers) contains a `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` marker is
   NOT-EVIDENCE, never a failure; a body quoting a marker in later text
   stays evidence.
2. **Trusted clean-analysis check-run or commit status**
   (`REVIEW_GATE_TRUSTED_STATUS_CONTEXTS`) succeeding on this head — but a
   pass must prove analysis RAN: a success matching
   `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` (e.g. "rate limited") is
   NOT-EVIDENCE, never a failure.
   On BOTH surfaces the NEWEST row/run per name decides (statuses by list
   order, check-runs by run id): an older clean success never outlives its
   reviewer's newer pending/failed/skip-marked round.
3. **Comment-form clean pass** (`REVIEW_GATE_COMMENT_REVIEWERS`): an issue
   comment by a trusted bot login — never the PR author, even if configured —
   binding the evidence to this head's sha (floor
   `REVIEW_GATE_SHA_PREFIX_FLOOR`).
4. **Operator override** (`REVIEW_GATE_OVERRIDE_CONTEXT`, legacy name
   `REVIEW_GATE_OUTAGE_CONTEXT`): a trusted operator's status carrying a
   NON-EMPTY reason, which is enforced and surfaced in the gate detail.
   Substitutes for MISSING evidence ONLY — it never overrides a
   changes-requested or an unresolved thread; fix findings and resolve
   threads first, then attest.

With `REVIEW_GATE_CARRY_FORWARD` (off by default), evidence at an ancestor
carries to head when the delta is provably in a class review would not
re-examine — docs-only, comment-only, identical tree. Never a waiver: real
evidence must exist, code changes always require fresh evidence, and the
fail-closed terms still apply.

Changes-requested and unresolved threads always fail closed. Every evidence
read fails LOUD (exit 2, no verdict); reads retry in-process up to `REVIEW_GATE_API_ATTEMPTS`
(default 1), and a zero-byte producer is a failed read, not an empty page
set. Review threads are counted across pages (100 per page, bound 20
pages / 2000 threads); past the bound — or when pagination metadata
cannot advance — the count reports overflow and fails closed to
`threads-open`.

**Trust model.** Trust keys on names only GitHub controls: the author login
of a review or comment, or the exact check/status context on repos where
every publisher is trusted. A comment body never establishes trust — it is
read only to BIND evidence to a commit. Where PR workflows hold `statuses:write`, the opt-in
`REVIEW_GATE_STATUS_PUBLISHER_REJECT` list rejects statuses minted by a
forgeable creator (typically `github-actions[bot]`) on both the
trusted-context and override reads. Statuses are read from the per-commit
statuses LIST endpoint, where every real publisher — GitHub Apps included —
carries a creator login; while the reject list is configured, a status with
no creator login is an anomaly and is not evidence (with the list empty, the
default, the filter is off entirely).

## The writer (`.agents/skills/review-gate/scripts/review-writer.sh`)

One workflow, defined on the default branch, is the only thing that writes
the gate status. It evaluates the predicate and converges the status —
nothing else.

- **Converge-all on every leg.** Every invocation converges EVERY open PR.
- **Relay / converge split.** PR-attached legs (`pull_request_target`,
  `pull_request_review`, `status`, an opted-in `check_run`) do NOT run the
  engine: they run a group-less relay job that dispatches a converge pass and
  exits. Only `workflow_dispatch` and `schedule` hold the single-writer group.
  The relay costs one non-evictable run per PR-attached event — size that
  before adopting on a capacity-limited runner pool
  ([references/adoption.md](references/adoption.md) § Updating an
  already-adopted copy).
- **The relay never exits non-zero — a pinned invariant.** It holds no
  `statuses` scope. Every fault warns and exits 0, and every wait is bounded;
  a sustained dispatch outage surfaces as **gate staleness**, healed by the
  cron floor and `pr-watch --heal`. Retry taxonomy and bounds: adoption.md
  § Updating an already-adopted copy — read it before editing a consumer's copy.
- **Write ordering.** Before any `success` post it re-reads the status and
  defers when any gate entry was created at/after this run's evaluation
  instant — a newer run's state AND description (which carries the audit
  detail) both stand; a failed re-read defers too. Downward posts never
  defer.
- **Idempotent.** When the current entry already matches state + description
  it no-ops.
- **Forks need no special case** — every leg holds a write-capable
  default-branch token. Exception: `pull_request_review` on a fork PR holds a
  read-only token, exits green as a no-op, and the cron floor converges it.
- **`pull_request_target` safety**: the job never executes PR-controlled
  code. Every checkout pins the default branch with credentials dropped.

## Scripts

```bash
# verdict for one head (env: GH_REPO, PR_NUMBER, HEAD_SHA[, PR_AUTHOR])
.agents/skills/review-gate/scripts/review-predicate.sh

# converge every open PR's gate status (env: GH_REPO)
.agents/skills/review-gate/scripts/review-writer.sh

# needs-attention reducer over open PRs (env: GH_REPO) — exit 0 nothing,
# 1 attention lines on stdout, 2 read errors. Flags: --heal (one writer
# dispatch on gate-stale, reported as an informational heal-dispatched
# line), --no-evaluate (predicate-skipping mode: thread,
# queue, and gate-status reads still run, so threads-open, disarmed, and
# the threads-driven gate-stale form all fire; verdict-driven forms need
# the predicate), --awaiting-after SECS (default: PR_REVIEW_WAIT_SECS)
.agents/skills/review-gate/scripts/pr-watch.sh [PR# ...]

# offline decision-table selftest (~1s, no network), run from the repo root
.agents/skills/review-gate/scripts/review-predicate-selftest.sh

# live replay against a throwaway sandbox repo — before any engine change
E2E_REPO=<owner>/<repo> .agents/skills/review-gate/tests/e2e-sandbox.sh
```

## Operations

**Watching one or many PRs without stalling.** Never key a hand-rolled
monitor on gate-state transitions. Run
`.agents/skills/review-gate/scripts/pr-watch.sh` (optionally `--heal`) on
the harness's wake-up mechanism: silence + exit 0 means nothing needs you;
attention lines name exactly what does. See adoption.md § Watching PRs as an agent.

**Reviewers are down / nothing is reviewing.** Run the internal review loop:
fix findings, resolve every thread, then post the override status with a real
reason. It cannot bypass an objection or an open thread.

**A PR that repairs the gate itself.** The writer always runs the merged
engine. Merge the repair PR with the ruleset's bypass actor and say so in the
commit message.

**A settings-change PR** is judged by the OLD config — a PR adding a trusted
login cannot have its own gate honor it. Merge via normal review or the
bypass actor.

## Settings

Every per-repo value is a `REVIEW_GATE_*` key (env > `kendex.settings.toml` >
default). Full table:
[references/settings.md](references/settings.md).

## Selftest — the engine's portable proof

`.agents/skills/review-gate/scripts/review-predicate-selftest.sh` pins the
decision table offline, running the real predicate against the invoking
repo's own resolved settings. Details: [DEVELOPMENT.md](DEVELOPMENT.md) § How
the selftest pins the decision table.

Every consumer's CI must run it as a deliberately **ungated** job (own job,
no `needs`).

## Adoption

Copy `.agents/skills/review-gate/templates/review-gate-writer.yml` into
`.github/workflows/` (repo-owned after copy; `kendex refresh` does not
sync workflow YAML), set the repo's
`REVIEW_GATE_*` values, add the ungated selftest job, and require the gate
context in the ruleset alongside the test aggregate. Full wiring:
[references/adoption.md](references/adoption.md). An adoption PR deletes the
local machinery it supersedes in the same PR.

For re-vendor PRs, suppress duplicate findings with the remedy-locus reviewer
instruction, never a reviewer path exclusion:
[references/vendored-paths.md](references/vendored-paths.md).
