# D013: A green pull request is admin-merged, and the queue is kept for CI, ruleset-input and shared-harness changes

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active (item 1's zero-bypass required-checks ruleset and the by-hand merge of item 2 → D016)

**Research**: —

**Supersedes**: [D003](D003-one-merge-path.md) in part: item 1's one merge path and item 3's zero bypass actors

**Approval**: owner decision 1790616596, 2026-09-28, relayed by the kendex overseer (lane mail 1790616843-3086369-26438); owner correction 1790623442, 2026-09-28, relayed by the kendex overseer (lane mail 1790623545-924328-13182); owner note 1790633650, 2026-09-28, relayed by the kendex overseer (lane mail 1790633853-3815502-10519); owner note 1790641164, 2026-09-29, relayed by the kendex overseer (lane mail 1790641268-2014274-22470)

**Applies to**: every lane's merge

## Context

The owner's words: "we have to use copilot and pi and we have to get it done as soon as possible. If that means turning on admin merges, that is fine. Turn on an admin merge. We are moving way too slow."

- The merge queue over the day before the decision: 148 merge-group Skill Tests runs created between 2026-09-27 17:00Z and 2026-09-28 17:40Z, 86 success, 51 failure, 11 cancelled, a median run of about 28 minutes (`gh run list -R vanillagreencom/kendex --event merge_group --workflow 'Skill Tests'` over that window, read 2026-09-28 19:03Z).
- Owner correction 1790623442 gives the record since the rule went on: five admin merges, kendex pull requests 3074, 3072, 3081 and 3089 and fleet pull request 486, one of them run by a lane, each green at its head.
- Owner note 1790633650 moved the admin-merge conditions into GitHub, as the Decision states. Who may bypass the queue is closed by the bypass list of ruleset 20569265, the queue ruleset.
- Owner note 1790641164 states that the three-ruleset layout the Decision gives stands on the default branch of hyprtrade, fleet, hyprtrade-io, kendex, vsys, memsira, drovr and vg, and that the owner's admin-role bypass is gone everywhere. All 17 repositories are set to squash merges only, auto-merge allowed, branch deleted on merge, and the squash commit taking the pull request title and body, with wikis off.
- The kendex rulesets, their names and their rules were read through the API on 2026-09-29 at 01:07Z (`gh api repos/vanillagreencom/kendex/rules/branches/main` and `gh api repos/vanillagreencom/kendex/rulesets/ID`). The bypass lists read `null` to the lane's token, and the fleet rulesets are not readable by it. The bypass actors, the removed admin-role bypass, the fleet ruleset ids and the layout on the other repositories come from owner note 1790641164.
- Fleet decision D066, items 2 to 4, says the same for the fleet repository.
- Owner decision 1790634126 took D003's restatement out of this pull request. KEN-2069 carried D003's status and the rewrite to this decision of [merge-rail.md](../architecture/merge-rail.md), review-gate [adoption.md](../../skills/review-gate/references/adoption.md), review-gate [SKILL.md § 4](../../skills/review-gate/SKILL.md#4-operations) and [merge-pr.md § 5](../../skills/orch/workflows/merge-pr.md#5-execute-the-merge) step 1, with [D016](D016-merge-route-reads-bypass.md).

## Decision

1. The default branch's rules sit in three rulesets, and no owner admin-role bypass stands on any of them. An admin merge therefore skips only the queue, and GitHub refuses it unless the required checks, the `Review gate` and every review thread are green on the current head, whoever runs it. The rulesets:
   - organization ruleset 24148602 (main protections (zero-bypass)) has no bypass actor; it holds `deletion`, `non_fast_forward`, `pull_request` (no approval required, review-thread resolution required, squash only) and `copilot_code_review` (review on push, drafts not reviewed);
   - a repository required-checks ruleset, kendex 24148610 (main required checks) and fleet 24148608, has no bypass actor; it holds `required_status_checks`, on kendex the `Review gate` and the CI jobs;
   - a repository merge-queue ruleset, kendex 20569265 (main merge queue) and fleet 23249651, holds only `merge_queue`, and the lanes app, `vanillagreen-fleet-lanes` (integration 4925608), is its only bypass actor.
2. Any holder of the lanes identity, a lane or the overseer, merges a green pull request with `gh pr merge N --squash --admin` instead of waiting in the queue, the Copilot and Pi chain first. No tooling route wraps the merge and no lane is barred from it. GitHub itself refuses a merge whose current head is not green.
3. The queue stays for a pull request that changes CI, a ruleset input or the shared test harness. That class is derived from the paths a change touches (owner decision 1790634126 item 4); KEN-2064 lands it in the harness-ci classifier, which merge-pr and pr-merge read. Until KEN-2064 lands, the overseer's judgement stands in for it.

## Rationale

- The owner's reason is speed, in the words quoted under Context. The queue's numbers bear it out: about four in ten merge-group runs failed or were cancelled (62 of 148), and a run takes a median of about half an hour, so a green pull request typically waits about half an hour in the queue after its own checks passed.
- The risk an admin merge carries is merging a head nobody checked, not who runs the merge. The two zero-bypass rulesets close that risk: their checks and thread resolution bind to the current head, and a push resets the checks. The head binding is GitHub's, so no tool mode and no actor rule is needed.
- A pull request that changes CI, a ruleset input or the shared test harness has not been judged by its PR run alone; the queue run is the only run that judges it.

**Revisit When**: the PR run runs every merge-group job for the touched paths (a P1 item the overseer files).

**References**: [D003](D003-one-merge-path.md), [D016](D016-merge-route-reads-bypass.md), KEN-2023, KEN-2069, fleet D066
