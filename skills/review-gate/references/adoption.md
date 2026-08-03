# Adopting the review-gate engine

How a consumer repo wires the shared engine: the CI gate job, the two
scaffold workflows, branch protection, per-repo settings, and the shape of
each known consumer's adoption PR.

## What an adoption PR contains

1. Vendor the skill (`vstack refresh` places
   `.agents/skills/review-gate/scripts/` and this reference). The sync
   verifies the SHIPPED copy: the vendored files are byte-for-byte the
   catalog's, and the consumer's drift check asserts the vendored copy
   matches, not the source.
2. Copy `templates/approval-rerun.yml` and `templates/approval-sweep.yml`
   into `.github/workflows/`, aligning the `ADAPT`-marked trigger filters
   with the repo's `REVIEW_GATE_*` values. These are one-time scaffolds —
   repo-owned after copy; workflow YAML is not an ongoing sync target.
3. Wire the repo's own `ci.yml`: a gate job (below) and the ungated
   selftest job.
4. Set the repo's `REVIEW_GATE_*` keys in `vstack.settings.toml`.
5. **Delete the local copies the engine supersedes in the same PR** — local
   predicate/refire scripts, selftests, and any duplicated gate steps. A
   redesign removes what it replaces, never leaves it dormant.
6. Repo-side wiring (below): required status context, thread-resolution
   ruleset, merge-queue handling.

## The CI gate job

The gate is evaluated once per run in a cheap early job; heavy jobs take
`needs: <gate-job>` and `if: needs.<gate-job>.outputs.approved == 'true'`.
Skipped required checks satisfy rulesets — safe because the pending gate
status is what blocks merge.

```yaml
  changes:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
      issues: read      # comment-form evidence, if configured
      checks: read
      statuses: write   # posts the gate status
    outputs:
      approved: ${{ steps.gate.outputs.approved }}
    steps:
      - uses: actions/checkout@<pinned-sha>
        with:
          ref: ${{ github.event.pull_request.head.sha || github.sha }}
          persist-credentials: false
      - name: Evaluate review gate
        id: gate
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GH_REPO: ${{ github.repository }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
          PR_AUTHOR: ${{ github.event.pull_request.user.login }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: |
          CTX="$(. .agents/skills/review-gate/scripts/lib/settings.sh && rg_setting REVIEW_GATE_CONTEXT "Review gate")"
          post() {
            gh api -X POST "repos/$GH_REPO/statuses/$1" \
              -f state="$2" -f context="$CTX" \
              -f description="$(printf %.140s "$3")" \
              -f target_url="$RUN_URL" >/dev/null
          }
          if [ "${{ github.event_name }}" != "pull_request" ]; then
            # Merge-queue entries are post-approval by construction, but the
            # queue still requires the gate context on the group sha.
            if [ "${{ github.event_name }}" = "merge_group" ]; then
              post "$GITHUB_SHA" success "merge queue entries are post-approval by construction"
            fi
            echo "approved=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          if line="$(.agents/skills/review-gate/scripts/review-predicate.sh)"; then
            verdict="${line#verdict=}"; verdict="${verdict%% *}"
            detail="${line#*detail=}"
          else
            # NO verdict was reached (transient API failure). Fail SAFE, not
            # red: post pending so merge stays blocked, skip the heavy jobs,
            # and let the scheduled sweep re-evaluate.
            verdict="error"
            detail="review-state read failed; the scheduled sweep retries"
          fi
          case "$verdict" in
            approved)              state=success ;;
            changes-requested)     state=failure ;;
            awaiting|threads-open|error) state=pending ;;
          esac
          post "$HEAD_SHA" "$state" "$detail"
          if [ "$verdict" = "approved" ]; then
            echo "approved=true" >> "$GITHUB_OUTPUT"
          else
            echo "approved=false" >> "$GITHUB_OUTPUT"
          fi
```

### Trust posture (`REVIEW_GATE_TRUST_PR_WORKFLOWS`)

The snippet above (PR-head checkout, one job holding `statuses: write`) is
the **self-evaluating** posture — acceptable only with
`REVIEW_GATE_TRUST_PR_WORKFLOWS = "true"`, i.e. on private, effectively
single-author repos that deliberately want the bootstrap property (a PR
fixing a broken predicate is evaluated by its own fixed copy, so the fix can
open its own gate; under a base-revision predicate the fix would be judged
by the very bug it repairs). The setting exists to make that trade an
explicit, visible choice.

The **safe** posture (default, `"false"`) never executes PR-controlled code
with a write-capable token:

- Split evaluation and posting: an `evaluate` job with **read-only**
  permissions (`statuses: read`, no write anywhere) checks out the **base
  revision** (`ref: ${{ github.event.pull_request.base.sha }}`, or fetch the
  default branch and `git show` the predicate out of it) and runs the
  base-revision predicate against the PR head's sha; a separate `post` job
  with only `statuses: write` and **no repo checkout at all** posts the
  status from the evaluate job's output.
- `persist-credentials: false` on every checkout in any job that executes
  repository code (the scaffold workflows already do this; they also pin
  their checkout to the default branch, which is the same base-revision
  property for the refire path).
- The exposure is asymmetric by permission: a consumer of the predicate that
  holds no `statuses: write` (e.g. a build job deciding whether to run) can
  at worst be tricked into an unwarranted build, not a green gate — but it
  is the same root cause, so the base-revision rule applies to every job
  that executes the predicate with any token.
- The split removes PR-controlled CODE from the write path, but on
  `pull_request` events the workflow DEFINITION itself still ships with the
  PR head: a same-repo collaborator PR can edit the posting job directly
  (fork PRs cannot — their token holds no `statuses: write`). Where
  collaborators are inside the threat model, the status writer of record
  must be a workflow defined on a trusted revision — exactly the property
  the scaffold rerun/sweep workflows already have (non-PR triggers,
  default-branch checkout). Rely on the scheduled sweep as that writer of
  record and treat the PR-side gate job as the latency optimization,
  mirroring the thread-resolution term below.

## The ungated selftest job

```yaml
  gate-selftest:
    # DELIBERATELY UNGATED: no `needs`, no approval condition, no path
    # filter. If the predicate is broken, nothing is ever approved, so a
    # gated selftest could never run when it matters. A separate job reds
    # the build without stopping the gate job from posting its status — a
    # PR with no gate status at all is stuck rather than blocked.
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

- Branch protection / ruleset: require the gate context (the repo's
  `REVIEW_GATE_CONTEXT` value) as a required status check.
- Keep (or add) the zero-bypass thread-resolution ruleset
  (`required_review_thread_resolution`) — the CI-side thread term is a
  latency optimization, not the enforcement point of record.
- Merge queue repos: the gate job must post the gate context on
  `merge_group` shas (the snippet's unconditional success post — queue
  entries are post-approval by construction). Verify the queue's required
  checks include the gate context and that rerun-in-place (never a separate
  review-triggered run) is preserved: enqueue counts every check-run on the
  head, and a stale failed required check from a superseded run blocks it.

## Per-repo settings

Concrete per-consumer value assignments are tracked on the org adoption issue
(vstack's issue tracker), not here — this table names each key's decision axis.
The three adopting consumers map onto the archetypes in the next section.

| Key | Decision axis |
|---|---|
| `REVIEW_GATE_CONTEXT` | The repo's protected commit-status name. A repo with an existing aggregate context (archetype C) either sets this to that existing name or renames the context AND updates branch protection/rulesets in the same adoption — a mismatch leaves merges blocked on an absent required check. |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | The repo's trusted clean-analysis reviewer context(s). A context previously trusted ad hoc gets an explicit entry here or stops counting. |
| `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` | Default closes the rate-limited-pass gap everywhere; empty is an explicit opt-out. |
| `REVIEW_GATE_COMMENT_REVIEWERS` | Only for repos with a comment-form reviewer (reviewer login + binding prefix); empty otherwise. |
| `REVIEW_GATE_SHA_PREFIX_FLOOR` | Only where a comment-form reviewer binds by SHA prefix. |
| `REVIEW_GATE_OUTAGE_CONTEXT` | Carries over unchanged (`vstack-reviewer-outage`) unless a repo renames its outage attestation. |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | Empty = any non-author (adoption-non-breaking). A repo closing the any-collaborator-COMMENTED gap lists its trusted reviewer logins. |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` keeps today's behavior; `approved` requires an APPROVED verdict. |
| `REVIEW_GATE_MAX_RERUN_ATTEMPTS` | Refire budget; n/a for a repo keeping its own convergence tool. |
| `REVIEW_GATE_TRUST_PR_WORKFLOWS` | `false` is the safe posture. `true` is a deliberate, documented re-affirmation for a self-evaluating repo (bootstrap property, private single-author) — never an accident of copying. |

## Per-consumer adoption shape

Three archetypes cover the current consumers; an adoption PR states which one
it is and follows that shape.

**Archetype R — reference-origin** (the repo whose local implementation this
engine was lifted from; adoption is a rename-in-place):

- Delete the repo-local `review-predicate.sh`, `approval-refire.sh`, and
  `review-predicate-selftest.sh`.
- Repoint the CI gate step, the selftest job, `approval-rerun.yml`, and
  `approval-sweep.yml` at `.agents/skills/review-gate/scripts/*.sh` — and
  every OTHER workflow that consumes the predicate (a second consumer
  workflow is easy to miss).
- If the repo keeps its self-evaluating posture, `REVIEW_GATE_TRUST_PR_WORKFLOWS
  = "true"` is the explicit re-affirmation; the alternative is rewiring the
  consuming workflows to the safe two-job shape above.

**Archetype M — minimal local gate** (predicate-only today, no sweep
workflow, thread resolution enforced at merge time rather than CI-side):

- Delete the repo-local predicate and repoint `approval-rerun.yml`; either
  copy `templates/approval-sweep.yml` to gain the thread-resolution backstop
  or record that the merge-time thread gate covers it.
- **Existing local waivers are an explicit adopt-or-drop decision.** The
  shared engine deliberately ships no exemptions (e.g. a docs-only
  review-received waiver computed by a repo-local classification script).
  Keep such a waiver as repo-local logic layered on top of the shared
  predicate, or drop it in the adoption PR with the behavior change stated —
  dropping silently is a regression.
- No comment-form reviewer → leave `REVIEW_GATE_COMMENT_REVIEWERS` empty.

**Archetype C — converge-based** (the largest adoption; **not a script
swap**):

- Such a repo runs a different architecture: its own flag-parsing gate/
  convergence CLI tools, an existing protected aggregate context name, a
  convergence sweep that deliberately never writes on read failure
  (retry + escalation instead of fail-loud writes), and no PR-ref triggers
  (convergence from `status` / `workflow_run` / `schedule` only).
- **Scope decision for the owner before implementation:** (a) adopt the full
  engine including refire/sweep convergence, or (b) adopt the shared
  **predicate only** — the evidence logic, where the live-observed gaps are —
  and keep the repo's convergence layer. The engine supports (b) cleanly:
  the predicate is a standalone script with a stable one-line verdict
  contract.
- **Align `REVIEW_GATE_CONTEXT` explicitly** with the existing protected
  context name (or rename the context and update rulesets in the same
  adoption); verify `merge_group` posting against the ruleset.
- Add the review-object trust keys and skip patterns — both close gaps
  observed live on this archetype's PRs.
