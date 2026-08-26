# Adopting the review-gate engine

How a repo wires the shared engine: the writer workflow, the ungated
selftest, rulesets, per-repo settings, and what an adoption PR deletes.

## The precondition — check before anything else

The gate never polices CI. A repo must satisfy ONE of these:

1. **A merge queue** whose required contexts include the repo's test
   aggregate (recommended).
2. **No held-back jobs** — every required check runs on every push.

Held-back jobs report `skipped`, and GitHub counts skipped as satisfied. The
live replay (`.agents/skills/review-gate/tests/e2e-sandbox.sh` from a
consumer root; `skills/review-gate/tests/e2e-sandbox.sh` in the catalog
repo) scenario 11 (queue backstop) must pass against a repo-shaped sandbox
on every adopting repo.

## What an adoption PR contains

1. **Vendor the skill** (`kendex refresh` places
   `.agents/skills/review-gate/scripts/` and these references). The
   consumer's drift check asserts the vendored copy matches the catalog
   byte-for-byte.
2. **Copy `.agents/skills/review-gate/templates/review-gate-writer.yml`**
   into `.github/workflows/`.
   Repo-owned after the copy — workflow YAML is not an ongoing sync target.
   The one workflow is the ONLY writer of the gate status; every leg that
   runs the engine runs the DEFAULT-branch one (PR-attached legs relay).
   The ADAPT markers in the file are the three `|| 'main'` default-branch
   fallbacks (both checkouts and the relay's dispatch ref) — set them to the
   repo's default branch. Nothing else needs editing; renaming the copy
   needs no further change.
   Keep every line of the relay's `env:` block (`GH_REPO`, `DISPATCH_REF`,
   `WORKFLOW_REF`, `EVENT_NAME`, `CHECK_NAME`): change the fallback values,
   keep the lines.
3. **Add the ungated selftest job** to the repo's CI (below).
4. **Set the repo's `REVIEW_GATE_*` keys** in `kendex.settings.toml`
   (decision axes below; full key table in [settings.md](settings.md)).
5. **Delete everything the writer supersedes in the same PR** — gate jobs
   that read the predicate to condition CI, rerun/refire/sweep workflows and
   scripts, local predicate copies, duplicated gate steps.
6. **Repo-side wiring** (below): rulesets, merge queue, bypass actor.
7. **Reviewer instruction for the vendored tree** — wire the remedy-locus
   rule from [vendored-paths.md](vendored-paths.md), never a reviewer path
   exclusion.

## Recommended CI shape — the fast/full split

Recommended split: cheap fast checks (lint, typecheck, unit) run on every
push unconditionally; heavy suite jobs carry
`if: github.event_name == 'merge_group'` and run only in the queue. Running
everything on every push is also allowed. Jobs must NOT read the predicate
to decide whether to run.

## The ungated selftest job

```yaml
  gate-selftest:
    # DELIBERATELY UNGATED: no `needs`, no approval condition, no path
    # filter.
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

Run from the repo root (the selftest resolves the repo's own
`kendex.settings.toml`).

## Repo-side wiring

- **Ruleset**: require the gate context (the repo's `REVIEW_GATE_CONTEXT`
  value) alongside the test aggregate in the merge queue's required checks.
- **Thread resolution**: keep (or add) the zero-bypass
  `required_review_thread_resolution` ruleset.
- **Bypass actor**: the queue ruleset needs one (e.g. repository admin). It
  is the sanctioned merge path for gate-repair and settings-change PRs.
  State the bypass in the merge commit.
- **Merge queue**: the writer's `merge_group` leg posts the gate context on
  queue shas unconditionally. Verify the queue's required checks include
  both the gate context and the test aggregate.
- **Required checks must NOT include the writer's own job names.** Require
  the commit STATUS context only.

## Updating an already-adopted copy (relay/converge split)

Consumer copies are repo-owned; `kendex refresh` does NOT deliver this —
each repo takes it as its own PR. Template delta:

- A `request-converge` job (the relay) runs every PR-attached leg; the
  `write` job's `if:` is narrowed to `workflow_dispatch`/`schedule`.
- **Permissions**: the relay holds `actions: write` and nothing else — no
  `contents`, no `statuses`, no `issues`. `actions: write` authorizes
  dispatching **any** workflow in the repo plus cancelling, re-running and
  deleting runs, logs and artifacts. The relay checks nothing out and
  executes no PR-controlled code — never add a checkout to this job. The
  `write` job holds no `actions` scope.
- **The relay files no rolling escalation issue.** That stays on
  the `write` job. A sustained dispatch outage is detected through **gate
  staleness**: `pr-watch.sh --heal` dispatches one writer run per
  invocation on `gate-stale`. Each relay run's log carries a `::warning::`.
  For a louder signal, add it to staleness monitoring, not to the relay's
  scope.
- **`workflow_dispatch` must stay in `on:`** — it is the dispatch target.
  Dropping it strips every event-fast path down to the cron floor.
- A repo with the opt-in `check_run` trigger moves its check-name guard
  from the `write` job's `if:` to the relay's. The step refuses to dispatch
  on a `check_run` naming one of its own three jobs; that refusal is a
  literal list of the three job `name:` values — if you rename a job in
  your copy, rename it in the list too.
- **Check the ruleset first** if it ever named a writer JOB (rather than the
  gate status context): a required `Evaluate and write the review gate`
  would block every PR. Require the status context only.

- **The relay never exits non-zero.** Invariant when editing the copy. Every
  fault warns and exits 0, and every wait is bounded (`timeout` per dispatch
  attempt, a floored and capped backoff, and a `timeout-minutes` that
  outlasts the worst case). Do not restore fail-loud here.

  It makes two dispatch attempts, classifying the server's answer:

  | Answer | Wait | Recognized by |
  |---|---|---|
  | Rate limit | The named window, floored at 60s, plus bounded jitter; a window beyond 120s skips the retry | `retry-after`; `x-ratelimit-reset` *only when `x-ratelimit-remaining` is 0*; a header-less secondary limit, from its body or an HTTP 429 |
  | Transient | 5s | Anything else retryable |
  | Permanent | Not retried | 400; 404 (renamed workflow file); 405; 422 (bad ref); 401 (revoked token); 403 carrying no rate-limit evidence (`Resource not accessible by integration`) |

  Never treat `x-ratelimit-reset` as a wait instruction on its own.

Cost per repo: one extra Actions run per PR-attached event, up to about 4.2
minutes of runner hold in the worst modeled failure (inside the job's
5-minute budget), one or two content-creating API requests per run against
the secondary-limit budget, and one extra run lifecycle of event-fast
latency. The relay is group-less and coalesces nothing. Repos on a
constrained or self-hosted runner pool size that before adopting.

Verify after adopting — run both:

1. **Something was actually dispatched.** After a push to an open PR,
   `gh run list --workflow "Review gate writer" --event workflow_dispatch --limit 5`
   must show a run created just after it. If nothing appears, the relay's
   own run log carries a `::warning::` naming the cause (a missing
   `actions: write` is the usual cause).
2. **No cancelled check pins the PR.** Push twice in quick succession, then
   confirm `gh pr checks` shows no cancelled writer entry and
   `gh pr view --json mergeStateStatus` is not `UNSTABLE` on that account.

## Per-repo settings — decision axes

Concrete per-consumer values are tracked on the org adoption issue, not
here. Full key table: [settings.md](settings.md).

| Key | Decision axis |
|---|---|
| `REVIEW_GATE_CONTEXT` | The repo's protected commit-status name. Renaming means updating rulesets in the same adoption. |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | The repo's trusted clean-analysis reviewer context(s). Any context to trust needs an explicit entry here. |
| `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` | Default closes the rate-limited-pass gap everywhere; empty is an explicit opt-out. |
| `REVIEW_GATE_COMMENT_REVIEWERS` | Only for repos with a comment-form reviewer (login + binding prefix); empty otherwise. |
| `REVIEW_GATE_SHA_PREFIX_FLOOR` | Only where a comment-form reviewer binds by SHA prefix. |
| `REVIEW_GATE_OVERRIDE_CONTEXT` | The operator override context (legacy alias `REVIEW_GATE_OUTAGE_CONTEXT` still resolves; new installs set only the v2 key). |
| `REVIEW_GATE_STATUS_PUBLISHER_REJECT` | Set `github-actions[bot]` wherever PR workflows hold `statuses: write`. Requires the override to be posted by a non-Actions identity (operator PAT). Empty disables. |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | Empty = any non-author. List trusted reviewer logins to restrict. |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` counts COMMENTED reviews (for bots that never APPROVE); `approved` requires an APPROVED verdict. |
| `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` | Default closes the errored-auto-review gap; override where a repo's reviewer words its attestation differently; empty is an explicit opt-out. |
| `REVIEW_GATE_THREADS` | `enforce` unless the server-side zero-bypass thread ruleset is the enforcement point and CI-side latency is unwanted. |
| `REVIEW_GATE_CARRY_FORWARD` | Off by default. Enable `docs`/`comments` classes where re-review of provably review-inert deltas is not wanted. |

## Migrating a v1 consumer (rerun/sweep-era wiring)

A repo on the pre-writer machinery deletes, in one PR: its
`approval-rerun.yml` / `approval-sweep.yml` (or equivalents), any CI gate
job that evaluates the predicate to skip heavy jobs, any local refire /
convergence scripts, and the `REVIEW_GATE_TRUST_PR_WORKFLOWS` /
`REVIEW_GATE_MAX_RERUN_ATTEMPTS` keys (both retired). It adds the writer
workflow, applies the fast/full split to its CI, and updates its own docs
from the legacy override key to `REVIEW_GATE_OVERRIDE_CONTEXT`.

## Watching PRs as an agent (pr-watch)

`.agents/skills/review-gate/scripts/pr-watch.sh` is a needs-attention
reducer for sessions shepherding one or many PRs. Never watch gate-state
*transitions*.

Wrap it in whatever wake-up mechanism the harness has — the loop body is
always the same:

```bash
# cron / polling loop / harness monitor — silence means nothing needs you.
# Run it BARE, once; the exit code is the predicate. Never invoke it a
# second time to build a notification.
export GH_REPO=your-org/your-repo
.agents/skills/review-gate/scripts/pr-watch.sh --heal
```
(The `export` is its own line, not a command prefix.)

Exit 0 = silence (healthy); exit 1 = attention lines on stdout (threads to
triage — queued PRs annotated with the dequeue-first warning — objections,
a stale gate, a disarmed mergeable PR, reviewer silence past the quiet
period, or `head-moved` when a push landed mid-reduction — re-run); exit 2
= a PR could not be read (fail loud, never skipped).
`--heal` bounds itself to one writer dispatch per invocation. The orch
skill's waiters are the single-PR *foreground* waits; pr-watch is the
multi-PR *background* reducer.

## Verification

- The offline selftest passes from the repo root (configured layer =
  this repo's trust values).
- The consumer's vendored-copy drift check passes.
- The first PURE re-vendor PR after adoption carries a trusted non-author
  review object at head, and on the vendored tree no unresolved thread from a
  summary-capable reviewer, except one raising a carve-out regression (which
  correctly blocks — read before resolving anything). A location-bound
  reviewer's threads are recorded, not graded
  ([vendored-paths.md](vendored-paths.md) § Verifying on a real re-vendor PR).
- For engine changes (not adoptions): the live sandbox replay
  (`.agents/skills/review-gate/tests/e2e-sandbox.sh`) against the org
  sandbox.
