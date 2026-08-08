# Adopting the review-gate engine

How a repo wires the shared engine: the writer workflow, the ungated
selftest, rulesets, per-repo settings, and what an adoption PR deletes.

## The precondition — check before anything else

The gate answers "is this head reviewed?" and never polices CI. A repo must
therefore satisfy ONE of these, or untested code can merge and this engine
will not stop it:

1. **A merge queue** whose required contexts include the repo's test
   aggregate (recommended — the suite runs once, on the merged result).
2. **No held-back jobs** — every required check runs on every push.

Held-back jobs report `skipped`, and GitHub counts skipped as satisfied;
with no queue, a reviewed PR merges untested. The live replay
(`.agents/skills/review-gate/tests/e2e-sandbox.sh` from a consumer root;
`skills/review-gate/tests/e2e-sandbox.sh` in the catalog repo) exercises
the queue-backstop scenario — run it against a repo-shaped sandbox before
trusting an adoption.

## What an adoption PR contains

1. **Vendor the skill** (`vstack refresh` places
   `.agents/skills/review-gate/scripts/` and these references). The
   consumer's drift check asserts the vendored copy matches the catalog
   byte-for-byte.
2. **Copy `templates/review-gate-writer.yml`** into `.github/workflows/`.
   Repo-owned after the copy — workflow YAML is not an ongoing sync target.
   The one workflow is the ONLY writer of the gate status: it runs the
   default-branch engine on every leg, so no PR can influence its own gate
   evaluation and no trust-posture decision exists.
3. **Add the ungated selftest job** to the repo's CI (below).
4. **Set the repo's `REVIEW_GATE_*` keys** in `vstack.settings.toml`
   (decision axes below; full key table in [settings.md](settings.md)).
5. **Delete everything the writer supersedes in the same PR** — gate jobs
   that read the predicate to condition CI, rerun/refire/sweep workflows and
   scripts, local predicate copies, duplicated gate steps. A redesign
   removes what it replaces, never leaves it dormant.
6. **Repo-side wiring** (below): rulesets, merge queue, bypass actor.

## Recommended CI shape — the fast/full split

With the queue as the CI backstop, PR-push CI does not need to be the full
suite. The recommended split: cheap fast checks (lint, typecheck, unit) run
on every push unconditionally; the heavy suite jobs carry
`if: github.event_name == 'merge_group'` so they run only in the queue
while still reporting `skipped` contexts everywhere else — which satisfies
rulesets while the pending gate status blocks the merge. Review rounds then
bill zero heavy runner-minutes, and the full suite runs exactly once, on
the merged result, after review is done (a default-branch push re-run would
re-test the exact sha the queue just tested). Jobs must NOT read the
predicate to decide whether to run — that coupling is the v1 machinery this
engine deleted.

## The ungated selftest job

```yaml
  gate-selftest:
    # DELIBERATELY UNGATED: no `needs`, no approval condition, no path
    # filter. If the predicate is broken, nothing is ever approved, so a
    # gated selftest could never run when it matters.
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<pinned-sha>
        with:
          persist-credentials: false
      - name: Pin the review-gate decision table
        run: .agents/skills/review-gate/scripts/review-predicate-selftest.sh
```

Run from the repo root so the selftest resolves the repo's own
`vstack.settings.toml` — its configured layer generates approve/near-miss
cases from the repo's actual trust values.

## Repo-side wiring

- **Ruleset**: require the gate context (the repo's `REVIEW_GATE_CONTEXT`
  value) alongside the test aggregate in the merge queue's required checks.
- **Thread resolution**: keep (or add) the zero-bypass
  `required_review_thread_resolution` ruleset — the predicate's thread term
  is a latency optimization, not the enforcement point of record.
- **Bypass actor**: the queue ruleset needs one (e.g. repository admin). A
  PR that repairs a broken gate can never open its own gate — the writer
  always runs the merged engine — so the bypass actor is the sanctioned
  merge path for gate-repair and settings-change PRs. State the bypass in
  the merge commit.
- **Merge queue**: the writer's `merge_group` leg posts the gate context on
  queue shas unconditionally (queue entries are post-approval by
  construction). Verify the queue's required checks include both the gate
  context and the test aggregate.

## Per-repo settings — decision axes

Concrete per-consumer values are tracked on the org adoption issue, not
here. Full key table: [settings.md](settings.md).

| Key | Decision axis |
|---|---|
| `REVIEW_GATE_CONTEXT` | The repo's protected commit-status name. Renaming means updating rulesets in the same adoption — a mismatch leaves merges blocked on an absent required check. |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | The repo's trusted clean-analysis reviewer context(s). A context previously trusted ad hoc gets an explicit entry here or stops counting. |
| `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` | Default closes the rate-limited-pass gap everywhere; empty is an explicit opt-out. |
| `REVIEW_GATE_COMMENT_REVIEWERS` | Only for repos with a comment-form reviewer (login + binding prefix); empty otherwise. |
| `REVIEW_GATE_SHA_PREFIX_FLOOR` | Only where a comment-form reviewer binds by SHA prefix. |
| `REVIEW_GATE_OVERRIDE_CONTEXT` | The operator override context (legacy alias `REVIEW_GATE_OUTAGE_CONTEXT` still resolves; new installs set only the v2 key). |
| `REVIEW_GATE_STATUS_PUBLISHER_REJECT` | Set `github-actions[bot]` wherever PR workflows hold `statuses: write` — PR content can mint any status context through that identity, including the override. Requires the override to be posted by a non-Actions identity (operator PAT), which is the v2 posture. Empty disables. |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | Empty = any non-author (adoption-non-breaking). A repo closing the any-collaborator-COMMENTED gap lists its trusted reviewer logins. |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` counts COMMENTED reviews (for bots that never APPROVE); `approved` requires an APPROVED verdict. |
| `REVIEW_GATE_THREADS` | `enforce` unless the server-side zero-bypass thread ruleset is the enforcement point and CI-side latency is unwanted. |
| `REVIEW_GATE_CARRY_FORWARD` | Off by default. Enable `docs`/`comments` classes where re-review of provably review-inert deltas is not wanted. |

## Migrating a v1 consumer (rerun/sweep-era wiring)

A repo on the pre-writer machinery deletes, in one PR: its
`approval-rerun.yml` / `approval-sweep.yml` (or equivalents), any CI gate
job that evaluates the predicate to skip heavy jobs, any local refire /
convergence scripts, and the `REVIEW_GATE_TRUST_PR_WORKFLOWS` /
`REVIEW_GATE_MAX_RERUN_ATTEMPTS` keys (both retired with the machinery that
consumed them). It adds the writer workflow, applies the fast/full split to
its CI, and updates its own docs from the legacy override key to
`REVIEW_GATE_OVERRIDE_CONTEXT`. The PR's shape IS the deletion — the writer
replaces four workflows and every coupling between review state and CI
scheduling.

## Watching PRs as an agent (pr-watch)

The predicate and writer keep the GATE correct; `scripts/pr-watch.sh` is the
agent-side third piece — a needs-attention reducer for sessions shepherding
one or many PRs across hours. The failure mode it removes: an agent watching
gate-state *transitions* sleeps forever through a PR sitting steadily at
"pending because review threads are open" (no transition, no wake), which
has stranded multi-PR sessions for hours in production.

Wrap it in whatever wake-up mechanism the harness has — the loop body is
always the same:

```bash
# cron / polling loop / harness monitor — silence means nothing needs you.
# Run it BARE, once: the wake-up mechanism owns output capture (cron mails
# stdout; harness monitors surface stdout lines as events; a scheduler
# stores the log) and the exit code is the predicate. Never invoke it a
# second time to build a notification — that re-dispatches --heal's writer
# kick and can observe different state. The bare single command is also
# the one shape every restrictive harness classifier accepts.
GH_REPO=<owner>/<repo> .agents/skills/review-gate/scripts/pr-watch.sh --heal
```

Exit 0 = silence (healthy); exit 1 = attention lines on stdout (threads to
triage — queued PRs annotated with the dequeue-first warning — objections,
a stale gate, a disarmed mergeable PR, reviewer silence past the quiet
period); exit 2 = a PR could not be read (fail loud, never skipped).
`--heal` bounds itself to one writer dispatch per invocation. The orch
skill's waiters remain the single-PR *foreground* waits (nudge and
on-timeout policy live there); pr-watch is the multi-PR *background*
reducer they and harness monitors share.

## Verification

- The offline selftest passes from the repo root (configured layer =
  this repo's trust values).
- The consumer's vendored-copy drift check passes.
- For engine changes (not adoptions): the live sandbox replay
  (`tests/e2e-sandbox.sh`) against the org sandbox, which mirrors the fleet
  ruleset shape.
