# D028: A repository that adopts the harness-ci template proves each head in the merge queue alone

[← Decision Index](INDEX.md)

**Date**: 2026-10-17

**Status**: Active

**Research**: [KEN-4217](https://linear.app/vanillagreen/issue/KEN-4217); the owner's CI ruling of 2026-10-17 in Slack messages 1792196004, 1792197483 and 1792197507, relayed by Jarvis owner-notes 1792196688, 1792197529 and 1792197598

**Supersedes**: [D016](D016-merge-route-reads-bypass.md) in part, its queue paths: which setting a repository names them in, and what opens the admin route.

**Decision**: The owner ruled that a pull-request push runs no product CI in any repository, and that the merge-queue run is the only proof of a head. [D027](D027-merge-queue-proves-every-change.md) is the kendex half of that ruling; this record is the consumer half. A repository whose base settings name no `HARNESS_CI_PER_PUSH_REASON` reads every change queue-only, so `pr-merge` never takes `--admin`. A workflow that passes the change-class action's `queue-only-default: true`, as the harness-ci template does, stands every product lane down on `pull_request` and `push` for that default, and its nightly run on the default branch runs every lane. A repository that names a reason runs its lanes on each pull-request push. Only there does the classifier read `HARNESS_CI_QUEUE_PATHS`, the `:queue` marks and the queue selector, and only there can a change take the admin route under D016's ruleset rules.

**Why**: The owner asked whether CI must run on every pull request, given its cost, and ruled one rule for every repository with a named reason for each exception. The default reaches a consumer through its own adoption of the template, because a ci.yml copied before the default passes no input and keeps its lanes. A repository with no merge queue sets the reason, because there no merge-group run proves the head.

**Rejected**: D016's queue-path list as the default: a change outside the list takes the admin route on a pull-request run, which the owner removed. A stand-down for every consumer at the catalog refresh: a consumer with no merge queue would merge heads that no lane ran.

**Revisit when**: A served repository cannot use a merge queue and has no reason it can name, or merge-queue waits cost more than the pull-request runs they replaced.
