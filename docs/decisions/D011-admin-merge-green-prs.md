# D011: A green pull request is admin-merged, and the queue is kept for CI, ruleset-input and shared-harness changes

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: —

**Supersedes**: the zero-bypass part of [D003](D003-one-merge-path.md) (one merge path)

**Approval**: owner decision 1790616596, 2026-09-28, relayed by the kendex overseer (lane mail 1790616843-3086369-26438); owner correction 1790623442, 2026-09-28, relayed by the kendex overseer (lane mail 1790623545-924328-13182)

**Applies to**: every lane's merge; [../architecture/merge-rail.md](../architecture/merge-rail.md), [../../skills/orch/workflows/merge-pr.md](../../skills/orch/workflows/merge-pr.md), [../../skills/review-gate/references/adoption.md](../../skills/review-gate/references/adoption.md), [../../skills/review-gate/SKILL.md](../../skills/review-gate/SKILL.md#4-operations) § 4, [../../skills/orch/references/oversee-events.md](../../skills/orch/references/oversee-events.md), `skills/github/scripts/commands/pr-merge.sh`

## Context

The owner's words: "we have to use copilot and pi and we have to get it done as soon as possible. If that means turning on admin merges, that is fine. Turn on an admin merge. We are moving way too slow."

- The merge queue over the day before the decision: 148 merge-group Skill Tests runs created between 2026-09-27 17:00Z and 2026-09-28 17:40Z, 86 success, 51 failure, 11 cancelled, a median run of about 28 minutes (`gh run list -R vanillagreencom/kendex --event merge_group --workflow 'Skill Tests'` over that window, read 2026-09-28 19:03Z).
- The `vanillagreen-fleet-lanes` app (integration 4925608) is now a bypass actor, mode always, on kendex ruleset 20569265. The thread-resolution ruleset 20569268 is unchanged.
- Owner correction 1790623442 gives the record since the rule went on: five admin merges, kendex pull requests 3074, 3072, 3081 and 3089 and fleet pull request 486, one of them run by a lane, each green at its head.

## Decision

This is the target state. KEN-2037 lands the admin mode in `pr-merge.sh` and moves the lane merge route and every file **Applies to** names to these rules. Until it lands, the actor reads the PR head SHA, checks that the PR checks, the `Review gate` and the open review threads are clean at that SHA, and only then runs `gh pr merge N --squash --admin --match-head-commit SHA` by hand.

1. A pull request whose PR checks, `Review gate` and open review threads are clean at its head SHA is admin-merged instead of waiting in the queue, the Copilot and Pi chain first.
2. The admin route is one admin mode of the github skill's `pr-merge.sh`. It reads the PR head SHA, refuses unless the PR checks, the `Review gate` and the open review threads are clean at that SHA, and passes `--admin --match-head-commit SHA` to `gh pr merge`, so GitHub refuses the merge if the head moved after the check. A lane or the overseer runs that same mode.
3. A raw `gh pr merge --admin` is not the route. The docs state this rule; no hook and no control enforces it.
4. The queue is kept for a pull request that changes CI, a ruleset input or a shared test harness, and for a pull request whose PR run skipped a shard the change touches.

## Rationale

- The owner's reason is speed, in the words quoted under Context. The queue's numbers bear it out: about four in ten merge-group runs failed or were cancelled (62 of 148), and a run takes a median of about half an hour, so every green pull request waits at least that long in the queue after its own checks passed.
- The risk an admin merge carries is merging a head nobody checked, not who runs the merge. Binding the merge to the head SHA its checks, `Review gate` and threads were read at closes that risk for whichever actor runs it, so the route names a mode, not an actor.
- A pull request that changes CI, a ruleset input or a shared harness, or whose PR run skipped a touched shard, has not been judged by its PR run alone; the queue run is the only run that judges it.

**Revisit When**: the PR run runs every merge-group job for the touched paths (a P1 item the overseer files).

**References**: [D003](D003-one-merge-path.md), KEN-2023, KEN-2037
