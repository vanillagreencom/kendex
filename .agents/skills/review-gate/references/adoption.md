# Adopting the review-gate engine

How a repo wires the shared engine: the writer workflow, the validate step,
rulesets, per-repo settings, and what an adoption PR deletes.

## The precondition — check before anything else

The gate never polices CI. A repo must satisfy ONE of these:

1. **A merge queue** whose required contexts include the repo's test
   aggregate (recommended).
2. **No held-back jobs** — every required check runs on every push.

Held-back jobs report `skipped`, and GitHub counts skipped as satisfied.

## What an adoption PR contains

1. **Vendor the skill** (`kendex refresh` places
   `.agents/skills/review-gate/scripts/` and these references). The
   consumer's drift check asserts the vendored copy matches the catalog
   byte-for-byte.
2. **Copy `.agents/skills/review-gate/templates/review-gate-writer.yml`**
   into `.github/workflows/`, VERBATIM. It carries no per-repo values.
   Repo-owned after the copy — workflow YAML is not an ongoing sync target.
   The one workflow is the ONLY writer of the gate status; every leg that
   runs the engine runs the DEFAULT-branch one (PR-attached legs relay).
   Renaming the copy needs no further change. Keep every line of the relay's
   `env:` block (`GH_REPO`, `DISPATCH_REF`, `WORKFLOW_REF`, `EVENT_NAME`,
   `CHECK_NAME`).
3. **Add the validate job** to the repo's CI (below).
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

## The validate job

```yaml
  review-gate-validate:
    # DELIBERATELY UNGATED: no `needs`, no approval condition, no path
    # filter.
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<pinned-sha>
        with:
          persist-credentials: false
      - name: Validate this repo's review-gate installation
        run: .agents/skills/review-gate/scripts/validate.sh
```

One verdict line per check; exit 0 clean, 1 findings, 2 the check could not
run. It answers repo-own questions only — the engine is installed and
runnable here, the committed `REVIEW_GATE_*` values are legal, the
carry-forward exclusions still match tracked paths, and the adopted workflow
still meets this template's contract. It re-runs no engine test suite: the
selftest and the wrapper suites are the ENGINE's proofs and run in the kendex
repo on every change to it.

Value rules come from the engine, not from a copy of it: the settings half
calls `review-predicate.sh --check-config`, which resolves and validates
every key and exits without reading any evidence or needing a PR.

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
- The opt-in `check_run` trigger ships commented out. To enable it,
  uncomment the two trigger lines and set the repository variable
  `REVIEW_GATE_CHECK_RUN_NAME` to the reviewer's check name — the relay's
  `if:` already reads it, so no expression is hand-edited. An unset variable
  matches no check name, so the trigger without the variable relays nothing.
  The step separately refuses to dispatch on a `check_run` naming one of its
  own three jobs; that refusal is a literal list of the three job `name:`
  values — if you rename a job in your copy, rename it in the list too.
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
| `REVIEW_GATE_OVERRIDE_CONTEXT` | The operator override context. Empty disables the source. |
| `REVIEW_GATE_STATUS_PUBLISHER_REJECT` | Set `github-actions[bot]` wherever PR workflows hold `statuses: write`. Requires the override to be posted by a non-Actions identity (operator PAT). Empty disables. |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | Empty = any non-author. List trusted reviewer logins to restrict. |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` counts COMMENTED reviews (for bots that never APPROVE); `approved` requires an APPROVED verdict. |
| `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` | Default closes the errored-auto-review gap; override where a repo's reviewer words its attestation differently; empty is an explicit opt-out. |
| `REVIEW_GATE_THREADS` | `enforce` unless the server-side zero-bypass thread ruleset is the enforcement point and CI-side latency is unwanted. |
| `REVIEW_GATE_CARRY_FORWARD` | Off by default. Enable `docs`/`comments` classes where re-review of provably review-inert deltas is not wanted, and `vendored` where a `kendex refresh` push should carry. |
| `REVIEW_GATE_VENDORED_PATHS` | With `vendored`: the render trees to trust as kendex output (`.agents/*;.claude/skills/*` and the harness dirs kendex writes). Bytes under them are not reviewed on carry, so hook scripts and instruction markdown stay in `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`. |

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

pr-watch reduces OPEN PRs only, and the gate opens on the first non-author
review with no quiet period — so a review round landing in the queue's final
minutes merges before anyone reads it. `merged-sweep.sh` is the same reducer
over recently-merged PRs, emitting one `post-merge-findings` line per merged
PR that carries a review or review thread created after its `mergedAt` with
no disposition reply:

```bash
export GH_REPO=your-org/your-repo
.agents/skills/review-gate/scripts/merged-sweep.sh
```

Same line shape and exit codes, so one consumer reads both. It keeps its own
per-repo state (`MERGED_SWEEP_STATE_DIR`, default `tmp/review-gate-merged-sweep`):
a finding surfaces once and stays quiet while unchanged, which makes exit 0
mean "nothing NEW". Pass `--no-state` to re-read everything still
outstanding — the audit form.

## Verification

- `.agents/skills/review-gate/scripts/validate.sh` exits 0 from the repo
  root.
- The consumer's vendored-copy drift check passes.
- The first PURE re-vendor PR after adoption carries a trusted non-author
  review object at head, and on the vendored tree no unresolved thread from a
  summary-capable reviewer, except one raising a carve-out regression (which
  correctly blocks — read before resolving anything). A location-bound
  reviewer's threads are recorded, not graded
  ([vendored-paths.md](vendored-paths.md) § Verifying on a real re-vendor PR).
