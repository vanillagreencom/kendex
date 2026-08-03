---
name: review-gate
description: "Org-wide PR review-gate engine: a commit-status merge gate driven by a single review-evidence predicate (review objects, trusted clean-analysis checks, comment-form clean passes, outage attestation), convergence scripts, an offline decision-table selftest, and one-time CI workflow scaffolds. Load when wiring, adopting, tuning, or debugging a repo's review gate or its REVIEW_GATE_* settings."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Review Gate

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

A shared merge gate for repos whose reviews come from bots and humans that
signal in different ways. One predicate script is the single source of truth
for "is this PR head reviewed?"; a commit status posted from its verdict
blocks merge; convergence scripts and workflows keep that status current as
review state changes. Consumers vendor `scripts/` via `vstack refresh` and
configure trust per repo in `vstack.settings.toml` — nothing repo-specific is
hard-coded in the engine.

## Status model

The gate posts one commit status (context: `REVIEW_GATE_CONTEXT`, default
`Review gate`) on the PR head. It is a required context, so `pending` blocks
merge without painting the PR red.

| Verdict | Status | Meaning |
|---|---|---|
| `awaiting` | `pending` | No review evidence for this head yet. |
| `threads-open` | `pending` | Evidence exists but review threads are unresolved. |
| `changes-requested` | `failure` | A reviewer objects to the current head. Red means a human/bot objection (or a genuinely broken build) — nothing else. |
| `approved` | `success` | Only from a run attempt whose gate evaluated open (the attempt that actually executes the heavy jobs), or the refire's prior-success fast path. |
| (exit 2, no verdict) | `pending` | An evidence read failed or config is invalid; take no action, retry later. |

Zero-bypass compatible: while the gate is closed the heavy jobs SKIP (a
skipped required check satisfies rulesets — safe precisely because the
pending gate status is what blocks the merge), and nothing ever posts
`success` without proof an approved attempt ran on that exact sha.

## Evidence sources (`scripts/review-predicate.sh`)

Evidence for the CURRENT head is any of:

1. **Review object** at the exact head from a non-author, non-dismissed
   login — restricted to `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` when
   set, and to APPROVED reviews when
   `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE = "approved"`. Approval is never
   superseded by a later COMMENTED from the same reviewer; only a later
   CHANGES_REQUESTED withdraws it.
2. **Trusted clean-analysis check-run or commit status**
   (`REVIEW_GATE_TRUSTED_STATUS_CONTEXTS`) succeeding on this head — but a
   "pass" must prove analysis ran: a success whose output/description
   matches `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` (e.g. "rate limited") is
   NOT-EVIDENCE, never a failure — it is silence, and silence is what the
   `awaiting` path already handles.
3. **Comment-form clean pass** (`REVIEW_GATE_COMMENT_REVIEWERS`): an issue
   comment by a trusted bot login — never the PR author, even if configured
   — whose body binds the evidence to this head's sha (full sha or a short
   prefix, bare or backtick-quoted; floor
   `REVIEW_GATE_SHA_PREFIX_FLOOR`).
4. **Reviewer-outage attestation** (`REVIEW_GATE_OUTAGE_CONTEXT`): a trusted
   orchestrator's status posted only on genuine total reviewer silence.
   Substitutes for MISSING evidence only.

Changes-requested and unresolved threads always fail closed, even with
evidence present. Every evidence read fails LOUD (exit 2, no verdict) — a
transient API error must never flip a healthy PR's merge state. More than
100 review threads reports overflow and fails closed to `threads-open`.

**Trust model.** Trust keys on names only GitHub controls: the author login
of a review or comment (exact match on the bot login) or the exact
check/status context on repos where every publisher is trusted. A comment
body is never trusted to establish trust — it is read only to BIND evidence
to a commit, so a stale comment cannot vouch for a later push.

## Scripts

```bash
# verdict for one PR head (env: GH_REPO, PR_NUMBER, HEAD_SHA[, PR_AUTHOR])
.agents/skills/review-gate/scripts/review-predicate.sh

# converge the gate status + rerun-in-place for one head (same env; QUIESCE=0|1)
.agents/skills/review-gate/scripts/approval-refire.sh

# offline decision-table selftest (~1s, no network); run it from the repo root
.agents/skills/review-gate/scripts/review-predicate-selftest.sh
```

`approval-refire.sh` posts pending/failure directly (pending blocks on its
own, no check-run churn) and opens the gate only by re-running the head's
completed `pull_request` runs — or a direct `success` post when a prior gate
success proves an approved attempt already ran on that sha. Reruns are capped
by `REVIEW_GATE_MAX_RERUN_ATTEMPTS`.

## Settings

Every per-repo value is a `REVIEW_GATE_*` key (env > `vstack.settings.toml` >
default). Full key table with per-repo values, and the workflow trust posture
(read-only evaluate job, no-checkout post job, `persist-credentials: false`):
[references/settings.md](references/settings.md).

## Selftest — the engine's portable proof

`scripts/review-predicate-selftest.sh` pins the decision table offline: a
`gh` shim on PATH answers from fixtures and applies `--jq` through real jq,
so the real predicate runs unmodified — no network, ~1s. Every case ending
`approved` is paired with a near-miss that must not. Two layers: a mechanism
layer with forced configurations pinning every engine behavior, and a
configured layer that re-derives the approve/near-miss battery from the
invoking repo's own resolved `REVIEW_GATE_*` values — a repo trusting a
different bot tests its own trust list, not someone else's defaults.

Every consumer's CI must run it as a deliberately **ungated** job (own job,
no `needs`, no approval condition): a broken predicate approves nothing, so
a selftest behind the gate could never run when it matters; a separate job
reds the build without stopping the gate status from posting.

## Adoption

`templates/approval-rerun.yml` and `templates/approval-sweep.yml` are
one-time scaffolds copied into `.github/workflows/` by a repo's adoption PR
(repo-owned after copy; workflow YAML is not synced by `vstack refresh`).
The repo's own CI wires a gate job that evaluates the predicate and posts
the status, plus the ungated selftest job. Full wiring, branch-protection
steps, merge-queue notes, and per-repo values:
[references/adoption.md](references/adoption.md). An adoption PR deletes the
local copies it supersedes in the same PR — a redesign removes what it
replaces, never leaves it dormant.
