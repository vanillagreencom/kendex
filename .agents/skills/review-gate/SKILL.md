---
name: review-gate
description: "Load to wire, adopt, tune, or debug a repo's review gate or its REVIEW_GATE_* settings."
summary: "Org-wide PR review gate: one predicate answers whether this exact head is reviewed, one writer posts the answer as a merge-blocking commit status."
license: MIT
user-invocable: true
dependencies:
  required: [harness-ci]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.1.0"
tags: [review]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Review Gate

The gate answers ONE question: **has this exact PR head been reviewed?** It posts that answer as a commit status the repo's branch rules require. It does not check CI, re-run anything, or reason about jobs.

Two greens do NOT mean a review happened. `REVIEW_GATE_MODE = "off"` evaluates no evidence when the class policy is inactive or resolves to `current`; it attests only that the repo disabled the gate. A class policy `bot` decision still requires review evidence. Merge-group statuses never read the mode and post green as "merge-queue entry: post-approval by construction". See [`REVIEW_GATE_MODE` in the settings table](references/settings.md).

## Decision table

| Verdict | Status | Meaning |
|---|---|---|
| `approved` | `success` | Evidence exists for this head, the whole diff sits under `REVIEW_GATE_RENDER_PATHS`, or `REVIEW_GATE_DOCS_ONLY = "none"` and the shared CI classifier accepts the diff as docs-only, both lanes only under an inactive class policy; no standing objection; no unresolved threads. For an inactive or `current` class policy, `REVIEW_GATE_MODE = "off"` evaluates no evidence term. Success there means only "gate disabled", stated in the status description. |
| `awaiting` | `pending` | No review evidence for this head yet. |
| `threads-open` | `pending` | Evidence exists, but review threads are unresolved. A thread the merge route resolved under its retired waiver counts as unresolved while the waiver stands, by the rule in `scripts/lib/waiver.sh`: [README class policy](README.md#class-policy). |
| `unmeasured` | `pending` | The class policy is active and the change classifier could not measure this head's class. The status names the classifier's cause. No evidence is read. Fix what the cause names; the next pass measures again. |
| `changes-requested` | `failure` | A reviewer objects. Red means objection, never a build failure. |
| `untracked-claim` | `failure` | A disposition reply that claims tracking and names no issue fails the gate. |
| `unreasoned-decline` | `failure` | A decline whose reason strips to nothing against the label vocabulary fails the gate. |
| `suppressed-findings` | `failure` | A review body at the commit the gate relies on — the head, or the carry base once carry supplies the evidence — carries a `Suppressed comments (N)` or `Previously missed (N)` block: findings that never became threads. Either title counts, written as a markdown heading or as a `<details>` summary. The status names the count and the file:line list. It has no dedicated settings key. A class policy `none` decision skips it. `REVIEW_GATE_MODE = "off"` skips it for an inactive or `current` class policy. An entry clears when the PR author answers it in an issue comment carrying a line `Dispositions at <sha>` that names this head, plus a line per entry opening with the entry's own `file:line` token — bare as the status prints it, or bold or backticked as the review body does — followed by `Fixed in <sha>`, `Declined: <reason>` or `Tracked: <ID>`. That marker is the only thing that binds the comment to the head. The whole term clears when that commit carries no such block. |
| `class-unresolved` | `pending` | Under an active class policy, the step that resolves this pull request's class exited non-zero: its temporary checkout, the path check or the source preparation failed, or `review-policy` failed other than by its exit 3 `unmeasured` record. No evidence was read. A failure to find the trusted repository root, resolve the base or fetch the commits, and a policy record the predicate cannot read, stay exit 2 with no verdict. The cause can be the pull request or the runner; the status names the head and the writer's log names the cause. A `success` already on the head stands. The pass converges every other pull request, then fails, and the next pass retries this one. |
| (exit 2, no verdict) | *unchanged* | A read failed or config is invalid. Take NO action; retry next pass. |

`awaiting` pending text names the head; which sources open the gate is [references/settings.md](references/settings.md) § Reading the pending status. How the reply-parsing failure verdicts read a reply is [DEVELOPMENT.md § Tracking-claim parsing](https://github.com/vanillagreencom/kendex/blob/main/skills/review-gate/DEVELOPMENT.md#tracking-claim-parsing) and [§ Decline parsing](https://github.com/vanillagreencom/kendex/blob/main/skills/review-gate/DEVELOPMENT.md#decline-parsing), and how `suppressed-findings` reads a body is [§ Suppressed-finding parsing](https://github.com/vanillagreencom/kendex/blob/main/skills/review-gate/DEVELOPMENT.md#suppressed-finding-parsing); what to write instead is orch's `references/finding-disposition.md`.

`REVIEW_GATE_CLASS_POLICY`, active by default, applies the [README class policy](README.md#class-policy) before this decision table, and that table states the scope a `none` row waives. `scripts/review-policy` is the one owner of the answer, and every other consumer reads it from there rather than re-deriving it.

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

`validate.sh` prints one verdict record per check: `ok` or `FAIL`, then `check=CODE value=VALUE`. Indented lines explain the result and the repair. Exit 0 = clean, 1 = findings, 2 = the check could not run at all (bad arguments, not a git repository, a missing file it derives checks from). Fix that first; a 2 is never a pass. Run it after every step below.

## 2. Adopt, when nothing is wired

The precondition comes first: the repo needs **a merge queue** that requires its CI jobs, or **no held-back jobs**; [references/adoption.md § The precondition](references/adoption.md#the-precondition--check-before-anything-else) is the one statement of both. Held-back jobs report `skipped`, which GitHub counts as satisfied, and a reviewed PR would merge untested. Confirm which one holds before wiring anything.

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

Then add the validate step to the repo's CI as its own job, with no `needs`, no path filter, no gate condition:

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

Finish with the repo-side wiring of ruleset and merge queue, with a bypass actor only where the standard admits one, and delete the local machinery the writer supersedes, in the same PR: [references/adoption.md](references/adoption.md).

## 3. Decide and repair

Keys a repo decides: [references/adoption.md](references/adoption.md) § Keys a repo decides. Repair by verdict line: the same reference's § Repair by verdict line.

## 4. Operations

**Watching one or many PRs without stalling.** Never key a hand-rolled monitor on review-state transitions. Run `.agents/skills/review-gate/scripts/pr-watch.sh` on the harness's wake-up mechanism: it reads GitHub's review state alone, and silence + exit 0 means nothing needs you; attention lines name exactly what does. See [Watching PRs as an agent](references/adoption.md#watching-prs-as-an-agent-pr-watch).

**A pull request drew no automatic review.** The automatic reviewer is armed by a branch ruleset, and a base outside that ruleset's target set never draws one. Request the review by hand with `gh pr edit <PR#> --add-reviewer @copilot`. The target set, the ruleset parameters, and the fallbacks when the manual request draws nothing: [references/automatic-review.md](references/automatic-review.md).

**Reviewers are down / nothing is reviewing.** Run the internal review loop: fix findings, resolve every thread, then post the override status with a real reason. It cannot bypass an objection or an open thread.

**A PR that repairs the gate itself.** The writer always runs the merged engine, so the repair cannot turn its own gate context green. The overseer merges it on its verified head under the overseer's own GitHub App, the one actor the standard admits in pull-request mode on both the required-checks and the merge-queue rulesets, and posts a notice naming the PR, the head, the broken check and the reason. The same route serves any required check that cannot pass: broken CI, a GitHub outage. A lane never takes it. The ruleset holding the approval and thread rules has no bypass actor, so both still hold. An organization with no such app adds one bypass entry for its owner to those two rulesets for the repair session, merges the repair directly, and removes both entries in the same session; the repair's commit message names them. No required context is changed, so no other repository loses its gate.

**A settings-change PR** is judged by the OLD config. A PR adding a trusted login cannot have its own gate honor it. Merge it through normal review.

# The engine

Evidence for the CURRENT head is any of:

1. A non-author review object accepted by the configured trust and state rules, carrying content of its own: a verdict, a body, or a thread it opened.
2. A trusted clean-analysis check-run or commit status that proves analysis ran.
3. A trusted comment-form pass bound to this head's SHA.
4. A trusted operator override with a reason, for missing evidence only.

Carry-forward never creates evidence or bypasses a fail-closed term. Objections and unresolved threads fail closed; an evidence-read failure exits 2 with no verdict. Evidence, trust, relay, and writer mechanics: [DEVELOPMENT.md § Predicate evidence and trust](https://github.com/vanillagreencom/kendex/blob/main/skills/review-gate/DEVELOPMENT.md#predicate-evidence-and-trust).

## Scripts

- `scripts/adopt-refresh.sh`: validate the existing app-secret environment, adopt the refresh workflow, and register exact workflow copies for render verification. [Setup and operation](references/adoption.md#automatic-consumer-refresh). `--help`
- `scripts/refresh-consumer.sh`: rebuild the rolling refresh branch from the default branch and open or update its pull request at any measured class. Only `render` arms app-token auto-merge. A `standard` refresh pull request stays unarmed; its body names the class, classifier cause and path. A repository maintainer reviews and merges it through the normal review and CI gates. An unmeasured class stops publication. Called by the refresh workflow.
- `scripts/refresh-reviews.sh`: on each open or merged rolling refresh pull request that the trusted `change-class` proves `render`, file every automatic review thread upstream, reply with the issue, then resolve it. A thread whose finding is not filed stays open and fails the run until it is resolved by hand. Called by the refresh workflow.
- `scripts/dispatch-refresh.sh`: signal all non-archived repositories visible to the catalog app installation.
- `scripts/validate.sh`: validate a consumer installation. `--help`
- `scripts/validate-workflow.sh`: compare the adopted workflow with the template; `--adopt` re-installs a new template over an unedited copy. `--help`
- `scripts/validate-standard.sh`: report, read-only, whether this repository's rulesets, their approval and stale-approval rules, classic branch protection, required contexts, app installation and app-secret environment match the organization standard, whose app, environment, secret names and required contexts are the `REVIEW_GATE_STANDARD_*` settings the repository declares ([references/settings.md](references/settings.md)), whether a job named `CI` ran for the pull request the default branch head merged and for that head's merge group, and whether a standard secret name also sits in a repository, organization or Dependabot secret or in another environment. A row it cannot read is a FAIL. `--help` names each row and the permission its reads need; a token holding only the lanes app's read-only set reads the bypass-actor, classic-protection, CI-context and app rows and the Dependabot scopes as unreadable.
- `scripts/provision-environment.sh`: the organization owner's write half of the standard's environment. From the owner's own machine, never a lane or CI, it creates or corrects the environment, its default-branch-only policy and its secrets in every repository of an organization that is not archived, and reports one record per repository. It resolves `REVIEW_GATE_STANDARD_APP`, `REVIEW_GATE_STANDARD_ENVIRONMENT` and `REVIEW_GATE_STANDARD_SECRETS`; which script reads which key is [references/settings.md](references/settings.md). `--dry-run` writes nothing. `--help`
- `scripts/review-predicate.sh`: evaluate one head or validate config. `--help`
- `scripts/review-policy`: map the shared classifier's answer to the configured review evidence policy. `--help`
- `scripts/review-writer.sh`: `workflow_dispatch` and `schedule` evaluate and converge every open PR; `merge_group` posts one queue success, while `WRITER_READ_ONLY=1` is a no-op. Its header documents the workflow-only contract.
- `scripts/pr-watch.sh`: reduce open PRs to attention lines read from GitHub's review state. `--help`

Engine selftests run in kendex CI ([DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/review-gate/DEVELOPMENT.md)). Re-vendor PRs: [references/vendored-paths.md](references/vendored-paths.md).
