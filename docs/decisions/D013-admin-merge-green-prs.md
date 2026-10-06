# D013: A green pull request is admin-merged; the queue is kept for CI, ruleset-input and shared-harness changes

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active (route selection → D016; approval and review status → D018)

**Research**: KEN-2023; KEN-3082 for the macOS shards

**Supersedes**: [D003](D003-one-merge-path.md) in part, its one merge path and its zero bypass actors

**Decision**: The default branch's rules sit in three rulesets with no owner admin-role bypass on any: an organization ruleset holding deletion, non-fast-forward, pull-request and Copilot-review rules with no bypass actor; a repository required-checks ruleset; and a repository merge-queue ruleset holding only `merge_queue`, whose bypass actor is the lanes app. An admin merge therefore skips only the queue, and GitHub refuses it unless the required checks and every review thread are green on the current head. A green pull request merges with `--admin` instead of waiting in the queue; the queue stays for a change to CI, a ruleset input or the shared test harness, a class the harness-ci classifier derives from the paths a change touches. Per fleet D066 item 3, the queue also takes every change whose job selection, `tools/ci-job-set`'s `queue_macos_shards`, names one of the merge group's macOS shards; the classifier reads that selection as its queue selector. How the route is chosen is [D016](D016-merge-route-reads-bypass.md).

**Why**: The owner's reason is speed: about four in ten merge-group runs failed or were cancelled and a run took a median of about half an hour, so a green pull request waited that long after its own checks passed. The risk an admin merge carries is merging a head nobody checked, and the two zero-bypass rulesets close it, since their checks bind to the current head and a push resets them. A change to CI itself has not been judged by its pull-request run alone. The queue's macOS shards run in a merge group and no pull request, so an admin merge lands a change those shards would test with them never run: on 2026-10-05 three macOS-only regressions reached main that way (KEN-2951).

**Rejected**: Keeping every merge in the queue: the wait and the failure rate above. Admitting an admin merge of a change that selects a queue macOS shard, leaving the regression to the main-push macOS roster: the owner chose the queue (fleet D066 item 3).

**Revisit when**: The pull-request run runs every merge-group job for the touched paths.
