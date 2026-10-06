# D016: The merge route reads the queue bypass and takes --admin itself; a repository names its own queue paths

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: KEN-2069

**Supersedes**: [D003](D003-one-merge-path.md) in part, the gate-repair break-glass; [D013](D013-admin-merge-green-prs.md) in part, the by-hand merge

**Decision**: `pr-merge` reads, under the merge's own token, the base branch's rulesets, each one's `current_user_can_bypass` and the classic protection, and merges with `--admin` bound to the verified head only where the queue is all `--admin` would skip: each ruleset holding `merge_queue` holds no other rule and answers bypass, every other ruleset answers `never`, a direct merge method is allowed, the base's queue is empty, and the change is not queue-only. Any other answer passes `--auto` and no `--admin`. The route and its cause are one `merge-route:` line. A repository names its own queue paths in `HARNESS_CI_QUEUE_PATHS`, read from the base commit's settings, and one that leaves the key unset reads queue-only on every change. A gate repair is the overseer app's, in pull-request mode on the checks and queue rulesets, never a lane's.

**Why**: GitHub answers the bypass question per caller and per ruleset, so the route asks GitHub instead of a brief or a setting. `--admin` skips every rule the token may bypass, so the route proves the queue is all it would skip. A direct push to the base invalidates every queued group, so the route requires an empty queue. An unlisted CI input must never merge without a merge-group run, so an unnamed list refuses the admin route.

**Rejected**: Lanes running raw `gh pr merge --admin`: each brief judges the route and a queue-only change can be admin-merged by mistake. A per-repository setting that turns the route on: it restates the ruleset's bypass list and drifts from it. Arming every pull request at creation: GitHub queues it before the route is read.

**Revisit when**: The pull-request run runs every merge-group job for the touched paths, or GitHub reports a ruleset's bypass through the rules endpoint itself.
