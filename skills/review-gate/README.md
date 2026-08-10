# review-gate

Blocks a merge until the PR head has actually been **reviewed** (unless the
repo disables the gate with `REVIEW_GATE_MODE = "off"` — then the status is
green without evidence and its description says so) — by a bot, a
human, or whatever mix a repo uses. It answers one question and posts the
answer as a commit status your branch rules require.

It does **not** check your tests. That is your branch protection's job, and
keeping the two separate is what makes this small enough to trust.

## How it flows

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  YOU OPEN A PR                                                   │
  └───────────────────────────────┬──────────────────────────────────┘
                                  │
              ┌───────────────────┴───────────────────┐
              │                                       │
     ╔════════▼═════════╗                    ╔════════▼═════════╗
     ║  YOUR CI         ║                    ║  YOUR REVIEWERS  ║
     ║ runs your checks ║                    ║  bots + humans   ║
     ╚════════╤═════════╝                    ╚════════╤═════════╝
              │                                       │
              │                          approval, or a clean-analysis
              │                          check, or an operator override
              │                                       │
              │                              ┌────────▼─────────┐
              │                              │   THE PREDICATE  │
              │                              │ is this exact    │
              │                              │ head reviewed? * │
              │                              └────────┬─────────┘
              │                                       │
              │                              ┌────────▼─────────┐
              │                              │   THE WRITER     │
              │                              │ posts the answer │
              │                              └────────┬─────────┘
              │                                       │
     ┌────────▼────────┐                     ┌────────▼─────────┐
     │ "tests" ✓/✗     │                     │ "Review gate"    │
     │ (your checks)   │                     │ ✓ reviewed *     │
     │                 │                     │ … awaiting       │
     │                 │                     │ ✗ changes wanted │
     └────────┬────────┘                     └────────┬─────────┘
              │                                       │
              └───────────────────┬───────────────────┘
                                  │  BOTH must be green
                    ┌─────────────▼──────────────┐
                    │      MERGE QUEUE           │
                    │  combines your PR with     │
                    │  the latest main and runs  │
                    │  the full suite on THAT    │
                    └─────────────┬──────────────┘
                                  │ green
                    ┌─────────────▼──────────────┐
                    │           MAIN             │
                    └────────────────────────────┘
```

\* Unless the repo sets `REVIEW_GATE_MODE = "off"`: the predicate then
evaluates no evidence at all, and the writer converges the status to green
with a "gate disabled by settings" description. On such a repo a green
PR-head `Review gate` attests only that the gate is off — it never proves a
review happened. That attestation is scoped to evaluated PR-head statuses:
merge-group (queue) statuses bypass the predicate entirely and always post
green as "merge-queue entry: post-approval by construction" without reading
the mode, so a green queue status is not a disabled-gate attestation.
Caveats: [references/settings.md](references/settings.md)
§ `REVIEW_GATE_MODE`.

The two columns are independent on purpose. The gate never inspects your CI,
and your CI never waits on the gate. Your branch rules require both.

**Where the CI savings come from:** the left column does not have to be your
full test suite. The recommended shape runs only fast, cheap checks on each
push — so multiple rounds of bot review never re-bill the expensive tests —
and lets the merge queue run the full suite exactly once, on the merged
result, after review is done. Repos that want maximum signal per push can
still run everything on every push; that is a per-repo CI choice this engine
deliberately stays out of.

## What the gate accepts as "reviewed"

Different reviewers signal differently, so the predicate accepts any of:

- a **review approval** at the exact head from a trusted login;
- a **clean-analysis check or status** succeeding on that head — for bots that
  only file a review when they have complaints (a "pass" that says *rate
  limited* or *skipped* is treated as silence, not approval). On both
  surfaces only the NEWEST row/run per name is considered: a reviewer
  starting a fresh round withdraws its own older clean success, so a newer
  pending, failed, or skip-marked run reads as silence, never as the old
  approval;
- a **comment-form pass** binding a trusted bot's comment to that head's sha;
- an **operator override** status carrying a written reason — the escape
  hatch for when every reviewer is down. It substitutes for *missing*
  evidence only: it can never override a changes-requested or an unresolved
  thread.

A standing changes-requested or any unresolved review thread always blocks,
whatever else is present. If an evidence read fails, the gate says so loudly
and posts nothing rather than guessing.

Push a new commit and evidence resets — it is bound to the exact head. The
one exception is opt-in **carry-forward**: a docs-only or comment-only change
can carry the previous head's review, so fixing a typo after review doesn't
restart the whole cycle.

## Before you adopt it

Your repo must satisfy **one** of these, or untested code can reach main and
this engine will not stop it:

1. **A merge queue** whose required checks include your test suite
   (recommended). The queue runs the suite on the merged result — once, on
   the code that actually ships.
2. **No held-back jobs** — every required check runs on every push.

The failure mode this prevents: if you hold tests back until review and have
no queue, GitHub records the held-back tests as *skipped*, and skipped counts
as satisfied. A reviewed PR would merge untested.

## Files

Paths are as installed in a consuming repo, under
`.agents/skills/review-gate/`.

| File | What it is |
|---|---|
| `.agents/skills/review-gate/SKILL.md` | The agent-facing contract: decision table, settings, operations. |
| `.agents/skills/review-gate/scripts/review-predicate.sh` | Answers "is this head reviewed?" — verdict on stdout, exit 2 means no verdict, take no action. Under `REVIEW_GATE_MODE = "off"` it evaluates nothing and answers `approved` with a gate-disabled attestation. |
| `.agents/skills/review-gate/scripts/review-writer.sh` | Posts that answer as the commit status. The whole writer. |
| `.agents/skills/review-gate/scripts/pr-watch.sh` | The agent-side reducer: "does any open PR need attention right now?" — unresolved threads (queued PRs annotated), standing objections, a gate the writer hasn't converged (`--heal` dispatches it once), a mergeable PR nothing will merge, reviewer silence past the quiet period. Silence on stdout + exit 0 means nothing needs you, which makes it a one-line loop/cron predicate. |
| `.agents/skills/review-gate/scripts/review-predicate-selftest.sh` | Offline proof of the decision table; runs ungated in CI so a broken predicate reds its own job instead of approving everything. |
| `.agents/skills/review-gate/templates/review-gate-writer.yml` | The one workflow to copy in. Repo-owned after copying. |
| `.agents/skills/review-gate/tests/e2e-sandbox.sh` | Live replay against a throwaway repo — re-run it before changing the engine. |
| `.agents/skills/review-gate/references/adoption.md` | Wiring, branch rules, per-repo settings. |
| `.agents/skills/review-gate/references/settings.md` | Every `REVIEW_GATE_*` key and the security reasoning behind the trust ones. |

Nothing repo-specific is hard-coded: consumers vendor the skill at
`.agents/skills/review-gate/` via `vstack refresh` and configure trust in
their own `vstack.settings.toml`.
