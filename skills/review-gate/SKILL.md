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
| `unreasoned-decline` | `failure` | A decline whose reason strips to nothing against the label vocabulary fails the gate. |
| (exit 2, no verdict) | *unchanged* | A read failed or config is invalid. Take NO action; retry next pass. |

Pending text names the head; which sources open the gate is
[references/settings.md](references/settings.md) § Reading the pending status.

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

## 3. Decide and repair

Keys a repo decides: [references/adoption.md](references/adoption.md) § Keys a
repo decides. Repair by verdict line: the same reference's § Repair by verdict
line.

## 4. Operations

**Watching one or many PRs without stalling.** Never key a hand-rolled monitor on gate-state transitions. Run `.agents/skills/review-gate/scripts/pr-watch.sh` (optionally `--heal`) on the harness's wake-up mechanism: silence + exit 0 means nothing needs you; attention lines name exactly what does. See [references/adoption.md](references/adoption.md) § Watching PRs as an agent.

**Reviewers are down / nothing is reviewing.** Run the internal review loop: fix findings, resolve every thread, then post the override status with a real reason. It cannot bypass an objection or an open thread.

**A PR that repairs the gate itself.** The writer always runs the merged engine. Merge the repair PR with the ruleset's bypass actor and say so in the commit message.

**A settings-change PR** is judged by the OLD config — a PR adding a trusted login cannot have its own gate honor it. Merge via normal review or the bypass actor.

# The engine

Evidence for the CURRENT head is any of:

1. A non-author review object accepted by the configured trust and state rules.
2. A trusted clean-analysis check-run or commit status that proves analysis ran.
3. A trusted comment-form pass bound to this head's SHA.
4. A trusted operator override with a reason, for missing evidence only.

Carry-forward never creates evidence or bypasses a fail-closed term. Objections
and unresolved threads fail closed; an evidence-read failure exits 2 with no
verdict. Evidence, trust, relay, and writer mechanics:
[DEVELOPMENT.md](DEVELOPMENT.md) § Predicate evidence and trust.

## Scripts

- `scripts/validate.sh`: validate a consumer installation. `--help`
- `scripts/validate-workflow.sh`: compare the adopted workflow with the template. `--help`
- `scripts/review-predicate.sh`: evaluate one head or validate config. `--help`
- `scripts/review-writer.sh`: `workflow_dispatch` and `schedule` evaluate and converge every open PR; `merge_group` posts one queue success, while `WRITER_READ_ONLY=1` is a no-op. Its header documents the workflow-only contract.
- `scripts/pr-watch.sh`: reduce open PRs to attention lines. `--help`

Engine selftests run in kendex CI ([DEVELOPMENT.md](DEVELOPMENT.md)). Re-vendor
PRs: [references/vendored-paths.md](references/vendored-paths.md).
