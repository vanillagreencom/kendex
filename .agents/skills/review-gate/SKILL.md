---
name: review-gate
description: "Load to wire, adopt, tune, or debug a repo's review gate or its REVIEW_GATE_* settings."
summary: "Org-wide PR review gate: one predicate answers whether this exact head is reviewed, one writer posts the answer as a merge-blocking commit status."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.1.0"
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
| `untracked-claim` | `failure` | A thread's disposition reply claims tracking and names no issue. |
| `unreasoned-decline` | `failure` | A thread's disposition reply declines and its reason strips to nothing against the predicate's label vocabulary: an empty reason, or only labels such as `frozen`, `out of scope`, `pre-existing`, a bare test count. Two positional name strips ride after that vocabulary and the filler words alike — a count takes the non-space run immediately in front of it, a slash-joined token is a path — so `lifecycle 104/104 and the full tools/guard pass` strips to nothing too; a name standing anywhere else survives. Read by shape, so a decline written without the colon counts too; a label beside a real reason is fine. The reach, and the shapes past it, are pinned in `tests/corpus/declines-known-limit.txt`. |
| (exit 2, no verdict) | *unchanged* | A read failed or config is invalid. Take NO action; retry next pass. |

**Reading the gate's own pending text.** `no review evidence at <sha> yet` is
the whole of the `awaiting` verdict. It names the head and nothing else: which
sources can open the gate is the repo's own settings, not a status description
GitHub keeps 140 characters of — read them in
[references/settings.md](references/settings.md).

Act on those settings, not on the pending state: where the configured sources
are bots and one has already reviewed this head, dispatch the writer instead
of waiting.

# Working in a consumer repo

## 1. Read the current state before changing anything

```bash
# Is the engine vendored and committed?
git ls-files .agents/skills/review-gate/scripts/ | head

# Is anything wired to write the gate?
git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml' \
  | xargs grep -l 'review-writer\.sh' 2>/dev/null

# What does the repo say about itself?
.agents/skills/review-gate/scripts/validate.sh; echo "exit $?"
```

`validate.sh` prints one verdict line per check and every `FAIL` line names
its own fix. Exit 0 = clean, 1 = findings, 2 = the check could not run at all
(bad arguments, not a git repository, a missing file it derives checks from —
fix that first; a 2 is never a pass). Run it after every step below.

## 2. Adopt, when nothing is wired

The precondition comes first: the repo needs **a merge queue** whose required
contexts include the test aggregate, or **no held-back jobs**. Held-back jobs
report `skipped`, which GitHub counts as satisfied, and a reviewed PR would
merge untested. Confirm which one holds before wiring anything.

```bash
# 1. vendor the engine as TRACKED files (CI checks out nothing else)
kendex refresh
git add .agents/skills/review-gate

# 2. copy the writer VERBATIM — it carries no per-repo values
cp .agents/skills/review-gate/templates/review-gate-writer.yml \
   .github/workflows/review-gate-writer.yml

# 3. assign the handful of values this repo actually decides (table
#    below); an install writes none of them, since each has a default
$EDITOR kendex.settings.toml

# 4. prove the install answers for itself
.agents/skills/review-gate/scripts/validate.sh
```

Then add the validate step to the repo's CI as its own job — no `needs`, no
path filter, no gate condition:

```yaml
  review-gate-validate:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<pinned-sha>
        with:
          persist-credentials: false
      - run: .agents/skills/review-gate/scripts/validate.sh
```

Finish with the repo-side wiring — ruleset, merge queue, bypass actor — and
delete the local machinery the writer supersedes, in the same PR:
[references/adoption.md](references/adoption.md).

## 3. The values a repo actually decides

Everything else has a working default. Full table:
[references/settings.md](references/settings.md).

| Key | Decide |
|---|---|
| `REVIEW_GATE_CONTEXT` | The protected commit-status name. Renaming it means updating the ruleset in the same PR. |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | The reviewer contexts whose clean pass counts. Any context to trust needs an explicit entry. |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | Empty = any non-author. List logins to restrict — do that wherever outside collaborators can review. |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` counts COMMENTED reviews (for bots that never APPROVE); `approved` requires an APPROVED verdict. |
| `REVIEW_GATE_COMMENT_REVIEWERS` | Only for a comment-form reviewer: `login:binding-prefix`. |
| `REVIEW_GATE_OVERRIDE_CONTEXT` | The operator override status context. |
| `REVIEW_GATE_THREADS` | `enforce`, unless a server-side zero-bypass thread ruleset is the enforcement point. |
| `REVIEW_GATE_CARRY_FORWARD` | Off by default. Turn on `docs`/`comments` where re-review of review-inert deltas is unwanted; `vendored` where `kendex refresh` pushes should carry, with the render trees listed in `REVIEW_GATE_VENDORED_PATHS`. |
| `REVIEW_GATE_VENDORED_PATHS` | The render trees `vendored` trusts as kendex output, e.g. `.agents/*;.claude/skills/*`. A hand-edit under them rides; keep hook scripts and instruction markdown in `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, which wins. |
| `REVIEW_GATE_MODE` | `enforce`. `off` is the one-switch disable, and it attests rather than evaluates. |

## 4. Repair, when validate reports FAIL

| Verdict line | What to do |
|---|---|
| assigns REVIEW_GATE_* key(s) the engine never reads | Fix the spelling against [references/settings.md](references/settings.md). The written value is being ignored. |
| a committed setting is not legal | The indented `::error` under it is the engine's own diagnosis; it names the key and the legal values. |
| carry-exclude … matches no tracked path | Fix the glob, or declare it in `REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC` when it guards paths that do not exist yet. |
| carry-exclude … anchored with a leading '/' | Drop the anchor: compare filenames are repository-relative. |
| prophylactic declaration … | Reconcile the ledger — every declaration names an active exclusion that still matches nothing. |
| no tracked workflow … runs review-writer.sh | Adopt (§2), or `git add` the workflow: Actions runs only what is committed. |
| has diverged from the shipped template | Re-copy `templates/review-gate-writer.yml` over the adopted file. The template carries no per-repo values, so a copy that differs is a copy someone edited; the line named under the verdict says where. Keep only the `check_run` opt-in's two trigger lines if that opt-in is on. |
| could not be read | A committed value the loader refuses — the indented diagnostic names the key and the shape it rejected. Fix the assignment; an unreadable value is never an empty one. |
| is not executable / does not parse | Re-run `kendex refresh` and commit the result. |

## 5. Operations

**Watching one or many PRs without stalling.** Never key a hand-rolled
monitor on gate-state transitions. Run
`.agents/skills/review-gate/scripts/pr-watch.sh` (optionally `--heal`) on
the harness's wake-up mechanism: silence + exit 0 means nothing needs you;
attention lines name exactly what does. See adoption.md § Watching PRs as
an agent.

**Reviewers are down / nothing is reviewing.** Run the internal review loop:
fix findings, resolve every thread, then post the override status with a real
reason. It cannot bypass an objection or an open thread.

**A PR that repairs the gate itself.** The writer always runs the merged
engine. Merge the repair PR with the ruleset's bypass actor and say so in the
commit message.

**A settings-change PR** is judged by the OLD config — a PR adding a trusted
login cannot have its own gate honor it. Merge via normal review or the
bypass actor.

# The engine

## Evidence sources (`.agents/skills/review-gate/scripts/review-predicate.sh`)

Evidence for the CURRENT head is any of:

1. **Review object** at the exact head from a non-author, non-dismissed
   login — restricted to `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` when set,
   and to APPROVED reviews when `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE =
   "approved"`. An approval is never superseded by a later COMMENTED from the
   same reviewer; only a later CHANGES_REQUESTED withdraws it. A row whose
   body's first line (after trimming leading whitespace and markdown quote
   markers) contains a `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` marker is
   NOT-EVIDENCE, never a failure.
2. **Trusted clean-analysis check-run or commit status**
   (`REVIEW_GATE_TRUSTED_STATUS_CONTEXTS`) succeeding on this head — but a
   pass must prove analysis RAN: a success matching
   `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` (e.g. "rate limited") is
   NOT-EVIDENCE, never a failure. On BOTH surfaces the NEWEST row/run per
   name decides: an older clean success never outlives its reviewer's newer
   pending/failed/skip-marked round.
3. **Comment-form clean pass** (`REVIEW_GATE_COMMENT_REVIEWERS`): an issue
   comment by a trusted bot login — never the PR author, even if configured —
   binding the evidence to this head's sha (floor
   `REVIEW_GATE_SHA_PREFIX_FLOOR`).
4. **Operator override** (`REVIEW_GATE_OVERRIDE_CONTEXT`): a trusted
   operator's status carrying a NON-EMPTY reason, which is enforced and surfaced in the gate detail.
   Substitutes for MISSING evidence ONLY — it never overrides a
   changes-requested or an unresolved thread; fix findings and resolve
   threads first, then attest.

With `REVIEW_GATE_CARRY_FORWARD` (off by default), evidence at an ancestor
carries to head when the delta is provably in a class review would not
re-examine — docs-only, comment-only, a committed kendex render tree,
identical tree. Never a waiver: real evidence must exist, code changes
outside those classes always require fresh evidence, and the fail-closed
terms still apply.

Changes-requested and unresolved threads always fail closed. Every evidence
read fails LOUD (exit 2, no verdict). Read bounds, retry budget and thread
pagination: [DEVELOPMENT.md](DEVELOPMENT.md) § Evidence reads.

**Trust model.** Trust keys on names only GitHub controls: the author login
of a review or comment, or the exact check/status context on repos where
every publisher is trusted. A comment body never establishes trust — it is
read only to BIND evidence to a commit. Where PR workflows hold
`statuses:write`, the opt-in `REVIEW_GATE_STATUS_PUBLISHER_REJECT` list
rejects statuses minted by a forgeable creator (typically
`github-actions[bot]`) on both the trusted-context and override reads.

## The writer (`.agents/skills/review-gate/scripts/review-writer.sh`)

One workflow, defined on the default branch, is the only thing that writes
the gate status. It evaluates the predicate and converges the status —
nothing else.

- **Converge-all on every leg.** Every invocation converges EVERY open PR.
- **Relay / converge split.** PR-attached legs (`pull_request_target`,
  `pull_request_review`, `status`, an opted-in `check_run`) do NOT run the
  engine: they run a group-less relay job that dispatches a converge pass and
  exits. Only `workflow_dispatch` and `schedule` hold the single-writer
  group. The relay costs one non-evictable run per PR-attached event — size
  that before adopting on a capacity-limited runner pool
  ([references/adoption.md](references/adoption.md) § Updating an
  already-adopted copy).
- **The relay never exits non-zero — a pinned invariant.** It holds no
  `statuses` scope. Every fault warns and exits 0, and every wait is bounded;
  a sustained dispatch outage surfaces as **gate staleness**, healed by the
  cron floor and `pr-watch --heal`.
- **`pull_request_target` safety**: the job never executes PR-controlled
  code. Every checkout pins the default branch with credentials dropped and
  refuses an empty default-branch resolution rather than falling back.
- **Idempotent, and ordered.** It no-ops when the current entry already
  matches, and defers a `success` post to any newer run's entry. Mechanics:
  [DEVELOPMENT.md](DEVELOPMENT.md) § Write ordering.

## Scripts

```bash
# validate THIS repo's installation (env: none) — the consumer's CI step
.agents/skills/review-gate/scripts/validate.sh

# is the adopted workflow still the shipped template? (equality, not
# re-derivation) — usable alone when only the workflow copy changed
.agents/skills/review-gate/scripts/validate-workflow.sh

# verdict for one head (env: GH_REPO, PR_NUMBER, HEAD_SHA[, PR_AUTHOR])
.agents/skills/review-gate/scripts/review-predicate.sh

# validate settings values alone, no evidence read, no PR required
.agents/skills/review-gate/scripts/review-predicate.sh --check-config

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
```

The offline decision-table selftest and the suites under tests/ are the
ENGINE's proofs and run in the kendex repo, not in a consumer's CI:
[DEVELOPMENT.md](DEVELOPMENT.md).

For re-vendor PRs, suppress duplicate findings with the remedy-locus reviewer
instruction, never a reviewer path exclusion:
[references/vendored-paths.md](references/vendored-paths.md). A committed
`kendex refresh` tree is the same problem with no pin over it, and its § The
harness-render variant routes every finding over the render upstream with no
carve-out.
