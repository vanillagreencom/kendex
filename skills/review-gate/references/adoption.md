# Adopting the review-gate engine

How a repo wires the shared engine: the writer workflow, the ungated
selftest, rulesets, per-repo settings, and what an adoption PR deletes.

## The precondition — check before anything else

The gate answers "is this head reviewed?" (or, under
`REVIEW_GATE_MODE = "off"`, attests that the repo disabled the question) and
never polices CI. A repo must
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
2. **Copy `.agents/skills/review-gate/templates/review-gate-writer.yml`**
   into `.github/workflows/`.
   Repo-owned after the copy — workflow YAML is not an ongoing sync target.
   The one workflow is the ONLY writer of the gate status: every leg that
   runs the engine runs the DEFAULT-branch one (PR-attached legs run no
   engine at all — they relay), so no PR can influence its own gate
   evaluation and no trust-posture decision exists.
   The ADAPT markers in the file are the three `|| 'main'` default-branch
   fallbacks (both checkouts and the relay's dispatch ref) — set them to the
   repo's default branch. Nothing else needs editing: the vendored script
   paths are already the consumer's, and the relay derives its own workflow
   file name from `github.workflow_ref`, so renaming the copy needs no
   further change.
   While editing those fallbacks, note that the relay's whole `env:` block is
   load-bearing, not just the three you are changing: every binding in it is
   read by the step, and a dropped line does not red the job — it degrades it.
   `GH_REPO` or `DISPATCH_REF` missing makes the relay refuse to dispatch at
   all (fail-closed, with a warning naming the binding) and every event falls
   to the cron floor; `WORKFLOW_REF` missing does the same; `EVENT_NAME` or
   `CHECK_NAME` missing turns off one of the loop breakers. Change the
   fallback values, keep the lines.
3. **Add the ungated selftest job** to the repo's CI (below).
4. **Set the repo's `REVIEW_GATE_*` keys** in `vstack.settings.toml`
   (decision axes below; full key table in [settings.md](settings.md)).
5. **Delete everything the writer supersedes in the same PR** — gate jobs
   that read the predicate to condition CI, rerun/refire/sweep workflows and
   scripts, local predicate copies, duplicated gate steps. A redesign
   removes what it replaces, never leaves it dormant.
6. **Repo-side wiring** (below): rulesets, merge queue, bypass actor.
7. **Reviewer instruction for the vendored tree** — the repo now merges
   re-vendor PRs whose whole delta is bytes already reviewed upstream, and
   every reviewer will re-review them into merge-blocking threads. Wire the
   remedy-locus rule from [vendored-paths.md](vendored-paths.md) rather than a
   reviewer path exclusion, which starves the gate on exactly this PR class.

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
- **Required checks must NOT include the writer's own job names.** The
  gate's enforcement point is the commit STATUS context, never the workflow
  that posts it. The writer's jobs skip by design on the legs they do not
  own (a queue entry runs only `merge-group`; a PR push runs only the
  relay), and a repo that required a writer job name would block on a
  context that leg never creates.

## Updating an already-adopted copy (relay/converge split, VST-210)

Consumer copies are repo-owned, so `vstack refresh` will NOT deliver this —
each repo takes it as its own PR. What changed in the template:

- A new `request-converge` job (the relay) now runs every PR-attached leg;
  the `write` job's `if:` narrowed to `workflow_dispatch`/`schedule`.
- **Permissions delta**: the relay holds `actions: write` and nothing else
  — because job-level `permissions` replace the workflow default rather than
  extend it, that is its complete scope: no `contents`, no `statuses`, no
  `issues`. Know what that scope actually grants, because it is coarser than
  its purpose: `actions: write` is the finest grain GitHub offers here, and it
  authorizes dispatching **any** workflow in the repo, plus cancelling and
  re-running runs and deleting runs, logs and artifacts. There is no
  one-workflow scoping. The containment argument is the job, not the token:
  the relay checks nothing out and executes no PR-controlled code, so nothing
  a PR author writes can reach that token. Keep it that way when you edit the
  copy — a checkout added to this job is what turns the delta into an
  exposure. The `write` job still holds no `actions` scope, so the writer
  still never re-runs CI.
- **The relay carries no VST-36 escalation, by decision.** The rolling
  incident issue stays on the `write` job. Because the relay also does not
  redden the PR (below), a sustained dispatch outage is detected through
  **gate staleness** rather than through any individual relay run: every
  event falls back to the cron floor, gates sit unconverged past that
  floor's period, and `pr-watch.sh --heal` is the reducer that already
  watches for exactly that across every open PR (`gate-stale` → one writer
  dispatch per invocation). Each relay run's own log carries a
  `::warning::`. This is a deliberate trade — not reddening PRs and not
  widening the relay's permissions, at the cost of no per-run alarm — so if
  you need a louder signal, add it to your staleness monitoring, not to the
  relay's scope.
- **`workflow_dispatch` must stay in `on:`** — it is the dispatch target,
  not just the manual kick. Dropping it strips every event-fast path down
  to the cron floor. (`workflow_dispatch` is one of the two events
  `GITHUB_TOKEN` is documented to trigger, which is what makes the relay
  work where the recursion suppression stops other self-triggering.)
- A repo with the opt-in `check_run` trigger moves its check-name guard
  from the `write` job's `if:` to the relay's. The relay's `if:` is a
  *negative* list, so with `check_run` on, this workflow's own job
  completions become relayable events — the step refuses to dispatch on a
  `check_run` naming one of its own three jobs, and your check-name guard on
  the `if:` is what keeps every other repo check from billing a skipped run.
  That refusal is a literal list of the three job `name:` values, so if you
  rename a job in your copy, rename it in the list too — the template's suite
  pins the two together, but only within the copy it reads. A rename that
  lands alone leaves a guard that matches nothing, and the relay holds no
  concurrency group to throttle the self-amplification that follows.
- **Check the ruleset first** if it ever named a writer JOB (rather than the
  gate status context): the job appearing on PR heads is now the relay, so a
  required `Evaluate and write the review gate` would block every PR. Per
  the wiring rule above, require the status context only.

- **The relay never exits non-zero.** Treat this as an invariant when you
  edit the copy: the job runs on PR-attached legs, so a red — or a hang long
  enough to be cancelled — is a failed check on the PR head and the defect
  this change removes. Every fault warns and exits 0, and every wait is
  bounded (`timeout` per dispatch attempt, a floored and capped backoff, and a
  `timeout-minutes` proven to outlast the worst case). Two
  dispatch attempts (the retry honors `retry-after`/`x-ratelimit-reset`,
  floored at 60s and capped at 120s — a 5-second retry lands inside every
  secondary-rate-limit window and could never succeed against the one
  failure class it exists for, and the cap keeps the wait inside the job's
  `timeout-minutes`. A window the server names beyond that cap is not waited
  out at all: the event defers to the cron floor rather than pay for a retry
  guaranteed to land inside the window. A plain transient retries in 5s — the
  minute is for rate limits, not for blips. A permanent answer is not retried
  at all: 400, 404 for a renamed workflow file, 405, 422 for a bad ref, 401
  for a revoked token, and **403 with no rate-limit evidence**, which is the
  `Resource not accessible by integration` shape a trimmed permissions block
  or an org token policy produces — the likeliest permanent failure this job
  has, since it is the only one needing `actions: write`. Note that
  `x-ratelimit-reset` rides on every GitHub response, so it counts as a wait
  instruction only when `x-ratelimit-remaining` is 0);
  on double failure it warns and exits 0 instead of exiting non-zero. The
  reasoning: it
  holds no `statuses` scope, so a skipped dispatch cannot make the gate look
  converged — only leave it stale, which the cron floor already owns —
  whereas a red relay check pins the PR at `UNSTABLE`, the defect being
  fixed. Do not "restore fail-loud" here without also moving the visibility
  somewhere that is not a PR's mergeability.

Why bother, per repo: without it, a burst of PR events leaves an evicted
writer run as a `CANCELLED` check on the PR, and `mergeStateStatus` reads
`UNSTABLE` until someone manually reruns it — a false not-ready signal for
every human and tool that reads it.

What it costs, per repo: one extra Actions run per PR-attached event —
seconds and a billed minimum on the success path, and up to about 4.2
minutes of runner hold in the worst modeled failure (a 60s-bounded attempt,
a wait capped at 120s plus up to 14s of jitter, a second 60s-bounded
attempt), which still fits inside the job's 5-minute budget. The relay is unconditional and deliberately group-less,
so unlike the writer group it coalesces nothing — that is one run per event,
including every `status` transition every CI provider posts on every open
head — and the event-fast path now waits on two runner allocations instead
of one. Repos on a constrained or self-hosted runner pool should size that
before adopting. The residual is honest: this removes *eviction-driven*
cancelled checks, not every cancelled check — a relay hung to its
`timeout-minutes` still leaves one.

Verify after adopting — and note that the first check alone passes even when
the relay is deferring every event, so run both:

1. **Something was actually dispatched.** After a push to an open PR,
   `gh run list --workflow "Review gate writer" --event workflow_dispatch --limit 5`
   must show a run created just after it. This is the only check that
   distinguishes a working relay from one that defers everything — the
   failure mode a missing `actions: write` produces. If nothing appears, the
   relay's own run log carries a `::warning::` naming the reason.
2. **No cancelled check pins the PR.** Push twice in quick succession, then
   confirm `gh pr checks` shows no cancelled writer entry and
   `gh pr view --json mergeStateStatus` is not `UNSTABLE` on that account.

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

The predicate and writer keep the GATE correct;
`.agents/skills/review-gate/scripts/pr-watch.sh` is the
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
export GH_REPO=your-org/your-repo
.agents/skills/review-gate/scripts/pr-watch.sh --heal
```
(The `export` is its own line, not a command prefix — inline
env-assignment prefixes are a rejected shape under restrictive Codex
approval classifiers.)

Exit 0 = silence (healthy); exit 1 = attention lines on stdout (threads to
triage — queued PRs annotated with the dequeue-first warning — objections,
a stale gate, a disarmed mergeable PR, reviewer silence past the quiet
period, or `head-moved` when a push landed mid-reduction — the findings
describe the old head, so re-run); exit 2 = a PR could not be read (fail
loud, never skipped).
`--heal` bounds itself to one writer dispatch per invocation. The orch
skill's waiters remain the single-PR *foreground* waits (nudge and
on-timeout policy live there); pr-watch is the multi-PR *background*
reducer they and harness monitors share.

## Verification

- The offline selftest passes from the repo root (configured layer =
  this repo's trust values).
- The consumer's vendored-copy drift check passes.
- The first PURE re-vendor PR after adoption carries a trusted non-author
  review object at head, and on the vendored tree no unresolved thread from a
  summary-capable reviewer, except one raising a carve-out regression, which
  blocks the re-vendor and is a correct outcome — read before resolving
  anything. A location-bound reviewer's threads are recorded, not graded
  ([vendored-paths.md](vendored-paths.md) § Verifying on a real re-vendor PR,
  whose pass rule this mirrors).
- For engine changes (not adoptions): the live sandbox replay
  (`.agents/skills/review-gate/tests/e2e-sandbox.sh`) against the org
  sandbox, which mirrors the fleet ruleset shape.
