# D011: A green pull request is admin-merged, and the queue is kept for CI, ruleset-input and shared-harness changes

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: —

**Supersedes**: the zero-bypass part of [D003](D003-one-merge-path.md) (one merge path)

**Approval**: owner decision 1790616596, 2026-09-28, relayed by the kendex overseer (lane mail 1790616843-3086369-26438)

**Applies to**: every lane's merge; [../architecture/merge-rail.md](../architecture/merge-rail.md), [../../skills/orch/workflows/merge-pr.md](../../skills/orch/workflows/merge-pr.md), [../../skills/review-gate/references/adoption.md](../../skills/review-gate/references/adoption.md), [../../skills/review-gate/SKILL.md](../../skills/review-gate/SKILL.md#4-operations) § 4, [../../skills/orch/references/oversee-events.md](../../skills/orch/references/oversee-events.md), `skills/github/scripts/commands/pr-merge.sh`

## Context

The owner's words: "we have to use copilot and pi and we have to get it done as soon as possible. If that means turning on admin merges, that is fine. Turn on an admin merge. We are moving way too slow."

- The merge queue over the day before the decision: 148 merge-group Skill Tests runs created between 2026-09-27 17:00Z and 2026-09-28 17:40Z, 86 success, 51 failure, 11 cancelled, a median run of about 28 minutes (`gh run list -R vanillagreencom/kendex --event merge_group --workflow 'Skill Tests'` over that window, read 2026-09-28 19:03Z).
- The `vanillagreen-fleet-lanes` app (integration 4925608) is now a bypass actor, mode always, on kendex ruleset 20569265. The thread-resolution ruleset 20569268 is unchanged.

## Decision

This is the target state. The lane merge route and every file **Applies to** names move to these rules under KEN-2037, and until it lands the lane runs the admin merge by hand, `gh pr merge N --squash --admin` under the lanes app's bypass, per the overseer's relay of owner decision 1790616596.

1. A pull request whose PR checks and `Review gate` are green and whose review has no open blocker is admin-merged (`gh pr merge N --squash --admin`) instead of waiting in the queue, the Copilot and Pi chain first.
2. The queue is kept for a pull request that changes CI, a ruleset input or a shared test harness, and for a pull request whose PR run skipped a shard the change touches.

## Rationale

- The owner's reason is speed, in the words quoted under Context. The queue's numbers bear it out: about four in ten merge-group runs failed or were cancelled (62 of 148), and a run takes a median of about half an hour, so every green pull request waits at least that long in the queue after its own checks passed.
- A pull request that changes CI, a ruleset input or a shared harness, or whose PR run skipped a touched shard, has not been judged by its PR run alone; the queue run is the only run that judges it.

**Revisit When**: the PR run runs every merge-group job for the touched paths (a P1 item the overseer files).

**References**: [D003](D003-one-merge-path.md), KEN-2023
