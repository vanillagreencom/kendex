# D011: A green pull request is admin-merged, and the queue is kept for CI, ruleset-input and shared-harness changes

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: —

**Supersedes**: the zero-bypass part of [D003](D003-one-merge-path.md) (one merge path)

**Approval**: owner decision 1790616596, 2026-09-28, relayed by the kendex overseer (lane mail 1790616843-3086369-26438)

## Context

The owner's words: "we have to use copilot and pi and we have to get it done as soon as possible. If that means turning on admin merges, that is fine. Turn on an admin merge. We are moving way too slow."

- The merge queue at 17:3xZ, 2026-09-28: 98 merge-group Skill Tests runs since 2026-09-27 17:00Z, 46 success, 41 failure, 11 cancelled, median 30 minutes.
- The `vanillagreen-fleet-lanes` app (integration 4925608) is now a bypass actor, mode always, on kendex ruleset 20569265. The thread-resolution ruleset 20569268 is unchanged.

## Decision

1. A pull request whose PR checks and `Review gate` are green and whose review has no open blocker is admin-merged (`gh pr merge N --squash --admin`) instead of waiting in the queue, the Copilot and Pi chain first.
2. The queue is kept for a pull request that changes CI, a ruleset input or a shared test harness, and for a pull request whose PR run skipped a shard the change touches.

## Rationale

- Fewer than half the merge-group runs succeeded, and a run takes a median 30 minutes, so the queue holds a green pull request longer than its own checks did.
- A pull request that changes CI, a ruleset input or a shared harness, or whose PR run skipped a touched shard, has not been judged by its PR run alone; the queue run is the only run that judges it.

**Revisit When**: the PR run runs every merge-group job for the touched paths (a P1 item the overseer files).

**References**: [D003](D003-one-merge-path.md), KEN-2023
