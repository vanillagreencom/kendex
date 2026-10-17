# D029: The repository owner merges a CI-input repair under a one-head bypass

[← Decision Index](INDEX.md)

**Date**: 2026-10-17

**Status**: Active

**Research**: [KEN-4249](https://linear.app/vanillagreen/issue/KEN-4249); fleet's D095 ([FLT-1355](https://linear.app/vanillagreen/issue/FLT-1355)), the organization rule that removed every app bypass from the organization's rulesets

**Supersedes**: [D016](D016-merge-route-reads-bypass.md) in part, the gate repair; [D018](D018-platform-review-requirements.md) in part, the overseer app's emergency merge; [D027](D027-merge-queue-proves-every-change.md) in part, the bypass actors

**Decision**: kendex's required-checks and merge-queue rulesets list no bypass actor, and its review-gate standard admits none, so the overseer app has no emergency merge. When a merge group cannot pass because a CI input read from the default branch broke (the classifier checkout, the lane declaration, the aggregate's needs or the change-class action), the overseer asks the repository owner, or the person the owner delegates, by mailbox, naming the broken input and the repair's pull request. That person adds a bypass for their own credential to both rulesets through the API and reads it back, merges that one repair head with `gh pr merge <N> --admin --match-head-commit <SHA>`, removes both bypasses and reads that back, and records both steps on the repair's work item. No lane runs a raw `--admin` merge and no app token gains a merge path, so D016's rule against a lane's raw admin merge holds with no exception.

**Why**: `pr-merge` never takes `--admin` for a queue-only change, whatever bypass a ruleset lists, and every kendex change is queue-only under D027, so a restored lanes-app queue bypass is never used. A repair whose broken input also fails its own required check is refused by the required-checks ruleset too. A person's own bypass on both rulesets, held for one head and read back when added and removed, is the smallest grant that merges the repair.

**Rejected**: Restoring the lanes app's merge-queue bypass for the repair: `pr-merge` sends the queue-only repair to the queue, and the required-checks ruleset still refuses a repair that fails its own check. A standing overseer-app bypass: the organization rule removed it.

**Revisit when**: `pr-merge` gains a route that merges a queue-only change past a broken merge group, or the organization's rulesets admit an app bypass again.
