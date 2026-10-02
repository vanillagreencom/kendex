# D016: The merge route reads the queue bypass and takes --admin itself; a repository names its own queue paths

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: —

**Supersedes**: [D003](D003-one-merge-path.md) in part: the gate-repair break-glass of items 1 and 3; [D013](D013-admin-merge-green-prs.md) in part: item 1's zero-bypass required-checks ruleset and item 2's by-hand merge

**Approval**: owner platform-first audit 1790636210 item C1, 2026-09-28, relayed as KEN-2069; fleet directive 1790637674 (fleet D066 items 2 to 4); owner note 1790642054, 2026-09-29, for the overseer app's bypass

**Applies to**: `skills/github/scripts/commands/pr-merge.sh`, `skills/orch/workflows/merge-pr.md` § 5 step 1, `skills/harness-ci/scripts/change-class`, `skills/review-gate/scripts/validate-standard.sh`

## Context

[D013](D013-admin-merge-green-prs.md) item 2 had every holder of the lanes identity run `gh pr merge N --squash --admin` by hand, with no tooling route around it, and left the queue-only judgement to the overseer until KEN-2064 derived it from paths. Lanes ran the raw command from their briefs, and `pr-merge --admin` refused on every class. Owner decision C1 moved the choice into the merge route.

## Decision

1. The immediate `pr-merge` reads, under the merge's own token, the base branch's rules, the `current_user_can_bypass` of each ruleset they name, and the branch's classic protection. It merges with `--admin` bound to the verified head by `--match-head-commit` only where the queue is all `--admin` would skip: each ruleset holding the `merge_queue` rule holds no other rule and answers `always`, `pull_requests_only` or `exempt`; every other ruleset answers `never`; classic protection is off; a direct merge allows one of the accepted methods, since GitHub holds a merge past the queue to the repository's methods and the base's `pull_request` rules, never to the queue's `merge_method`, and the admin merge passes that method; the base's merge queue is empty; and harness-ci's `change-class` reads the pull request not queue-only. Any other answer passes `--auto` and no `--admin`, so GitHub queues the pull request; GitHub refuses a merge on a queue base that passes neither. The route and its cause are named on one `merge-route:` line. `--auto` never passes `--admin`. Every `--auto` attempt reads the same route and arms nothing where it reads admin unless `--queue` explicitly requests the queue, so an ordinary arm cannot replace the direct route. The `--admin` flag and the refusal of the retired D003 settings are deleted.
2. The shipped `queue` list names this catalog's own CI inputs. A repository's own, such as a test harness or an aggregator outside `.github/`, are its `HARNESS_CI_QUEUE_PATHS`, read from the base commit's settings alone, never from the caller's environment. A repository that leaves the key unset reads queue-only on every change, so the admin route never runs where nobody has named the list. kendex sets it empty.
3. `validate-standard.sh` judges bypass actors per ruleset: a ruleset whose rules are `merge_queue` alone admits `REVIEW_GATE_STANDARD_QUEUE_BYPASS`, one whose rules are `required_status_checks` alone admits `REVIEW_GATE_STANDARD_CHECKS_BYPASS`, and every other ruleset admits none. Unset keys keep the zero-bypass reading. This folds KEN-2052.
4. A gate repair, and any merge whose required check cannot pass, is the overseer's GitHub App's, in pull-request mode on the checks and queue rulesets, never a lane's. An organization with no such app keeps the owner's break-glass entry, now on both rulesets.

## Rationale

- GitHub answers the bypass question per caller and per ruleset, so the route asks GitHub instead of a brief or a setting.
- GitHub applies `--admin` to every rule the token may bypass, not to the queue alone. So the route proves the queue is all it would skip, and the required checks, thread resolution and approvals still bind to the current head.
- A direct push to the base invalidates every queued merge group and repeats its full CI. The admin route requires an empty base queue to avoid that cost. An unreadable entry count takes the queue route.
- GitHub enqueues an armed pull request the moment its checks pass, and `gh pr merge --admin` on a queued one merges nothing. An arm at creation would therefore choose the queue before the route is read.
- The shipped list cannot know a consumer's CI inputs. Refusing the admin route where none is named is the only reading that never merges an unlisted CI input without a merge-group run.

## Alternatives Considered

| Alternative | Why rejected |
| --- | --- |
| Lanes run raw `gh pr merge --admin` (D013 item 2) | Each lane and brief judges the route, and a queue-only change can be admin-merged by mistake. |
| A setting that turns the admin route on per repository | It restates what the ruleset's bypass list already says, and drifts from it. |
| Arm every pull request at creation, as before | GitHub queues it before the lane reaches the route, so no lane pull request merges past the queue. |
| Refuse the admin route in every consumer | kendex's own list would then be the only one ever trusted; a consumer that names its paths gains nothing. |

**Revisit When**: the pull request run runs every merge-group job for the touched paths, which ends the queue-only class ([D013](D013-admin-merge-green-prs.md) Revisit When), or GitHub reports a ruleset's bypass through the rules endpoint itself.

**Verification**: `skills/github/tests/pr-merge.test.sh` § the merge route past the queue; `skills/harness-ci/tests/narrow-change.test.sh`, the queue rows and their controls; `skills/review-gate/tests/validate-standard.test.sh` § a ruleset holding one rule type.

**References**: [D003](D003-one-merge-path.md), [D013](D013-admin-merge-green-prs.md), KEN-2069, KEN-2052, KEN-2064, fleet D066
