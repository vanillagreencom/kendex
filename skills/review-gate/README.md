# review-gate

Blocks a merge until the PR head has actually been **reviewed** (unless the
repo disables the gate with `REVIEW_GATE_MODE = "off"` — then the status is
green without evidence and its description says so) — by a bot, a
human, or whatever mix a repo uses. It answers one question and posts the
answer as a commit status your branch rules require.

It does **not** check your tests. That is your branch protection's job, and
keeping the two separate is what makes this small enough to trust.

> **This skill runs in CI, so it must be COMMITTED to your repo.** GitHub
> Actions checks out only tracked files — a machine-local `.agents` install
> (symlinked or untracked) does not exist there. Vendor the skill as tracked
> files at `.agents/skills/review-gate/` (what `vstack refresh` produces in a
> consuming repo, committed), plus the copied workflow under
> `.github/workflows/`. If the engine is not in the commit, the gate is not
> in your CI.

## How it flows

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  YOU OPEN A PR                                                   │
  └───────────────────────────────┬──────────────────────────────────┘
              ┌───────────────────┴───────────────────┐
     ╔════════▼═════════╗                    ╔════════▼═════════╗
     ║  YOUR CI         ║                    ║  YOUR REVIEWERS  ║
     ║ runs your checks ║                    ║  bots + humans   ║
     ╚════════╤═════════╝                    ╚════════╤═════════╝
              │                          approval, or a clean-analysis
              │                          check, or an operator override
              │                                       │
              │                              ┌────────▼─────────┐
              │                              │   THE PREDICATE  │
              │                              │ is this exact    │
              │                              │ head reviewed? * │
              │                              └────────┬─────────┘
              │                              ┌────────▼─────────┐
              │                              │   THE WRITER     │
              │                              │ posts the answer │
              │                              └────────┬─────────┘
     ┌────────▼────────┐                     ┌────────▼─────────┐
     │ "tests" ✓/✗     │                     │ "Review gate"    │
     │ (your checks)   │                     │ ✓ reviewed *     │
     │                 │                     │ … awaiting       │
     │                 │                     │ ✗ changes wanted │
     └────────┬────────┘                     └────────┬─────────┘
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

\* Two greens do NOT prove a review happened: under `REVIEW_GATE_MODE = "off"`
the green attests only that the gate is off, and merge-group (queue) statuses
bypass the predicate entirely, always posting green as "merge-queue entry:
post-approval by construction". Caveats:
[references/settings.md](references/settings.md) § `REVIEW_GATE_MODE`.

The two columns are independent on purpose: the gate never inspects your CI,
and your CI never waits on the gate. The left column need not be your full
test suite either — the fast/full split, and where the savings come from:
[references/adoption.md](references/adoption.md) § Recommended CI shape.

## What the gate accepts as "reviewed"

Different reviewers signal differently, so the predicate accepts any of:

| Signal | What counts |
|---|---|
| Review approval | At the exact head, from a trusted login. |
| Clean-analysis check or status | A success on that head — for bots that only file a review when they have complaints. A "pass" that says *rate limited* or *skipped* is treated as silence, not approval. |
| Comment-form pass | A trusted bot's comment bound to that head's sha. |
| Operator override | A status carrying a written reason — the escape hatch for when every reviewer is down. It substitutes for *missing* evidence only: it can never override a changes-requested or an unresolved thread. |

A standing changes-requested or any unresolved review thread always blocks,
whatever else is present, and a failed evidence read says so loudly and posts
nothing rather than guessing. Push a new commit and evidence resets — it is
bound to the exact head. The one exception is opt-in **carry-forward**: a
docs-only or comment-only change can carry the previous head's review, so
fixing a typo after review doesn't restart the whole cycle.

## Before you adopt it

Your repo must satisfy **one** of these, or untested code can reach main and
this engine will not stop it: **a merge queue** whose required checks include
your test suite (recommended — the suite runs once, on the merged result), or
**no held-back jobs**, every required check running on every push. Held back
with no queue, tests record as *skipped*, which GitHub counts as satisfied: a
reviewed PR would merge untested. Wiring, and the sandbox proof of it:
[references/adoption.md](references/adoption.md) § The precondition.

## Files

Paths are as installed under `.agents/skills/review-gate/` in a consuming
repo; the engine's own files and internals: [DEVELOPMENT.md](DEVELOPMENT.md).

| File | What it is |
|---|---|
| `SKILL.md` | The agent-facing contract: decision table, settings, operations. |
| `templates/review-gate-writer.yml` | The one workflow to copy in. Repo-owned after copying. |
| `templates/vendored-paths.instructions.md` | Reviewer instruction for a byte-pinned vendored tree, so re-vendor PRs stop collecting duplicate blocking threads. Copy and fill; repo-owned after copying. |
| `references/adoption.md` | Wiring, branch rules, per-repo settings. |
| `references/settings.md` | Every `REVIEW_GATE_*` key and the security reasoning behind the trust ones. |
| `references/vendored-paths.md` | Why reviewer path exclusions starve the gate, and the remedy-locus rule that suppresses duplicate findings without doing so. |

Nothing repo-specific is hard-coded: consumers vendor the skill via `vstack
refresh` and set every per-repo `REVIEW_GATE_*` value in their own
`vstack.settings.toml` (env wins over the file, which wins over the default).
