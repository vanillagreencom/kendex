# D003: One merge path through the merge queue, consumers pull renders, organization rulesets with zero bypass

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active

**Research**: —

**Approval**: the owner, directive 1790300329, 2026-09-25

**Applies to**: every repository in the organization and every lane; [../architecture/merge-rail.md](../architecture/merge-rail.md), [../../skills/orch/workflows/merge-pr.md](../../skills/orch/workflows/merge-pr.md), [../../skills/orch/workflows/consumer-train.md](../../skills/orch/workflows/consumer-train.md)

## Context

A merge reached `main` by more than one route, and kendex renders reached consumers through a train the overseer drove from the control VM.

- Every merge of the last 14 pull requests before this decision was made by the owner's personal token through the overseer's admin verb (KEN-1646).
- The kendex merge-queue ruleset 20569265 listed Repository admin and two apps as bypass actors. The apps never used their bypass.
- Sandboxes already push with the lanes app's installation token, so a lane can arm auto-merge with that app.
- The queue is `ALLGREEN`, builds and merges up to five entries per group, squashes, and times a check out after 30 minutes.
- The consumer train runs on the control VM, driven by the overseer, and takes 5 to 35 minutes per train.
- PR 2860 lost about 40 minutes to a base-stale refusal: a pull request behind `main` had to restack before a direct merge.

## Decision

1. **One merge path.** Every repository merges through its merge queue, and the lanes app arms auto-merge. No ruleset has a bypass actor, no admin route exists, and no owner credential sits on the control VM. The queue serializes concurrent lanes and batches up to five pull requests per CI run, so a pull request behind `main` never restacks to merge. The queue run is cheap by class: the `merge_group` diff classifies like a pull request, a `render` or `trivial` group runs one job, and KEN-1750 removes the cargo lanes where no Rust path changed.
2. **Consumers pull.** kendex ships a workflow in its render. Each consumer runs it in its own GitHub Actions on `repository_dispatch` from kendex `main`, on a 30-minute schedule, and on `workflow_dispatch`. The workflow installs a pinned kendex, runs `kendex refresh --scope project --yes --leave` and `kendex verify`, commits to the one rolling branch `kendex/refresh`, opens or updates one rolling pull request, and arms auto-merge with the app token from organization secrets. The pull request is `render` class: no review, one CI job, then the queue. No overseer and no control-VM toolchain take part. kendex never pushes to a consumer.
3. **Organization rulesets.** Rulesets are organization rulesets that target all repositories. The default branch requires the merge queue, the required checks `Review gate` and one aggregate context `CI`, conversation resolution, and Copilot review, with zero bypass actors. Per-repository rulesets are deleted once the organization rulesets stand. A new repository inherits everything on adoption, plus the app installation. Settings are set once at the organization level, never per repository. The GitHub apps act; no step swaps one token for another.

## Rationale

- A direct merge that bypasses the queue rebuilds every running queue group, so a mixed path costs more than either path alone.
- The queue removes the base-stale restack, because the queue, not the lane, puts the pull request on top of `main`.
- The lanes app already holds a push token in every sandbox. Arming auto-merge with it needs no new credential and removes the owner's token from the control VM.
- A consumer's own Actions runner does the refresh, so propagation costs the control VM nothing and needs no overseer.
- One organization ruleset gives every repository the same required contexts and no bypass, and a new repository gets them by joining.

## Alternatives Considered

| Alternative | Why rejected |
| --- | --- |
| The admin route: the overseer merges with the owner's personal token (KEN-1646) | It needs an owner credential on the control VM and a bypass actor on every ruleset, and each admin merge rebuilds the running queue groups. |
| Per-repository rulesets | Each repository drifts on its own, and every setting change is repeated per repository. |
| kendex pushes to consumers: the consumer train from the control VM | It loads the control VM for 5 to 35 minutes per train, needs the overseer, and needs a write credential for every consumer. |
| A mixed path: direct merges beside the queue | A direct merge rebuilds every running queue group, which costs more than either path alone. |

## Consequences

- The overseer's admin verb, its settings, the `ORCH_MERGE_BYPASS` fast path and the merge-ready ask are retired (KEN-1777).
- Each repository reports one aggregate required context `CI` beside `Review gate`, and `merge_group` classifies through the same class job set (KEN-1778).
- The consumer train, its manual steps and `ORCH_CONSUMER_REPOS` are retired for the pulled workflow (KEN-1779).
- A lane's worktree comes from a current `main`, and the lane-host protocol drops its create-time refresh (KEN-1780).
- `kendex check` reports, read-only, whether a repository's rulesets, required contexts, app installation and organization secrets match this decision (KEN-1781).
- The kendex app and CLI open no pull request in a consumer; [../architecture/overview.md](../architecture/overview.md) § Decisions states it.

**Revisit When**: GitHub organization rulesets or the merge queue are unavailable to a repository kendex must serve; a consumer cannot run GitHub Actions or read organization secrets; or a queue run for a `render` or `trivial` group costs more time than the direct merge it replaced.

**Verification**: KEN-1781's `kendex check` report, once it lands; until then, the organization's ruleset settings in GitHub show zero bypass actors, the merge queue and the two required contexts.

**References**: KEN-1776, KEN-1646, KEN-1672, KEN-1750, KEN-1777, KEN-1778, KEN-1779, KEN-1780, KEN-1781
