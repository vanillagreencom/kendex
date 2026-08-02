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

| Key | memsira | drovr | hyprtrade |
|---|---|---|---|
| `REVIEW_GATE_CONTEXT` | `Review gate` | `Review gate` | `CI Required` (existing aggregate name) or `Review gate` on re-architecture — owner call |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | `Devin Review` | `Devin Review` | `Devin Review` (+ CodeRabbit's check if it is to be trusted — previously used ad hoc with no trust entry) |
| `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` | default | default | default — closes the live rate-limited-pass gap |
| `REVIEW_GATE_COMMENT_REVIEWERS` | `chatgpt-codex-connector[bot]:Reviewed commit:` | (empty — no comment-form reviewer) | (empty unless one is adopted) |
| `REVIEW_GATE_SHA_PREFIX_FLOOR` | `7` | n/a (default) | n/a (default) |
| `REVIEW_GATE_OUTAGE_CONTEXT` | `vstack-reviewer-outage` | `vstack-reviewer-outage` | `vstack-reviewer-outage` — carries over unchanged |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | (empty) | (empty) | set (e.g. `devin-ai-integration` + any trusted humans) — closes the any-collaborator-COMMENTED gap |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` | `any` | `approved` |
| `REVIEW_GATE_MAX_RERUN_ATTEMPTS` | `5` | `5` | n/a under its own convergence tool |
| `REVIEW_GATE_TRUST_PR_WORKFLOWS` | `true` (deliberate: bootstrap property on a private single-author repo — an explicit re-affirmation, not an accident) | `false` (safe posture; outside-contribution exposure not ruled out) | `false` |

## Per-consumer adoption shape

**memsira** — closest to a rename-in-place (its implementation is the
engine's reference):

- Delete `.github/scripts/review-predicate.sh`, `approval-refire.sh`,
  `review-predicate-selftest.sh`.
- Repoint `ci.yml`'s gate step and selftest job, `approval-rerun.yml`, and
  `approval-sweep.yml` at `.agents/skills/review-gate/scripts/*.sh`.
- Settings per the table. Setting `REVIEW_GATE_TRUST_PR_WORKFLOWS = "true"`
  is the explicit, documented re-affirmation of its self-evaluating posture
  (the alternative is rewiring `ci.yml` — and `ios.yml`, the predicate's
  second consumer — to the safe two-job shape above).
- No docs-only waiver to port (deliberately rejected there).

**drovr**:

- Delete `.github/scripts/review-predicate.sh` and repoint
  `approval-rerun.yml`; drovr has no sweep workflow today — copy
  `templates/approval-sweep.yml` to gain the thread-resolution backstop, or
  record that its merge-time thread gate covers it.
- **Docs-only waiver decision (owner call, flag in the adoption PR):**
  drovr's `classify-changes.sh` computes a `gate_exempt` docs-only waiver
  the shared engine deliberately does not have. Either keep it as
  drovr-local logic layered on top of the shared predicate, or drop it —
  dropping silently would be a behavior regression.
- drovr enforces thread resolution at merge time (its `pr-merge` gate +
  ruleset), not CI-side; the shared predicate's thread term simply adds the
  CI-side latency signal.
- No comment-form reviewer; leave `REVIEW_GATE_COMMENT_REVIEWERS` empty.

**hyprtrade** — the largest adoption; **not a script swap**:

- Its gate is a different architecture: flag-parsing CLI tools
  (`tools/ci-required-gate`, `tools/ci-review-convergence`), status name
  `CI Required`, a convergence sweep that deliberately never writes on read
  failure (universal 5-minute retry + escalation to a rolling incident
  issue instead of fail-loud writes), and no PR-ref triggers at all
  (convergence runs from `status` / `workflow_run` / `schedule` only, after
  PR-ref runs left permanently-retained non-green check runs on merge-bound
  heads).
- **Scope decision for the owner before implementation:** (a) adopt the
  full engine including refire/sweep convergence, or (b) adopt the shared
  **predicate only** (the evidence logic — which is where its two
  live-observed gaps are) and keep `ci-review-convergence` as the
  convergence layer. The engine supports (b) cleanly: the predicate is a
  standalone script with a stable one-line verdict contract.
- Merge queue: verify `merge_group` posting against its ruleset (above).
- Carry `REVIEW_GATE_OUTAGE_CONTEXT = "vstack-reviewer-outage"` over
  unchanged; add the review-object trust keys and skip patterns per the
  table — both close gaps observed live on its PRs.
