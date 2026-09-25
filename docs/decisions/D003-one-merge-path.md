# D003: One merge path through the merge queue, consumers pull renders, organization rulesets with zero bypass

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active

**Research**: —

**Approval**: the owner, directive 1790300329, 2026-09-25

**Applies to**: every repository in the organization and every lane; [../architecture/merge-rail.md](../architecture/merge-rail.md), [../../skills/orch/workflows/merge-pr.md](../../skills/orch/workflows/merge-pr.md), `skills/review-gate/templates/kendex-refresh.yml` (the refresh workflow template KEN-1779 adds)

## Context

A merge reached `main` by more than one route, and kendex renders reached consumers through a train the overseer drove from the control VM.

- Every merge of the last 14 pull requests before this decision was made by the owner's personal token through the overseer's admin verb (KEN-1646).
- The kendex merge-queue ruleset 20569265 listed Repository admin and two apps as bypass actors. The apps never used their bypass.
- Sandboxes already push with the installation token of the lanes app, `vanillagreen-fleet-lanes`, so a lane can arm auto-merge with that app.
- The queue is `ALLGREEN`, builds and merges up to five entries per group, squashes, and times a check out after 30 minutes.
- The consumer train runs on the control VM, driven by the overseer, and takes 5 to 35 minutes per train.
- PR 2860 lost about 40 minutes to a base-stale refusal: a pull request behind `main` had to restack before a direct merge.

## Decision

This is the target state, and each current route stays in place until the change that retires it lands. The admin merge and the `ORCH_MERGE_BYPASS` fast path stay until KEN-1777, the consumer train until KEN-1779, and each per-repository ruleset until the organization rulesets stand, the owner action KEN-1778 sequences.

1. **One merge path.** Every repository merges through its merge queue, and the lanes app arms auto-merge. No ruleset has a bypass actor, no admin route remains, and no owner credential sits on the control VM (KEN-1777). The queue serializes concurrent lanes and batches up to five pull requests per CI run, so a pull request behind `main` never restacks to merge. The queue run is cheap by class: the `merge_group` diff classifies like a pull request, a `render` or `trivial` group runs one job, and KEN-1750 removes the cargo lanes where no Rust path changed.
2. **Consumers pull.** kendex ships a refresh workflow template in its render (KEN-1779). `kendex refresh` never syncs workflow YAML, so the template reaches a consumer's `.github/workflows/` by adoption copy, as the review-gate writer template does per [adoption.md](../../skills/review-gate/references/adoption.md). The lanes app is installed on all repositories at the organization, and a workflow in kendex `main` sends `repository_dispatch` with the lanes app token to every repository the app is installed on. Each consumer's copy runs on that dispatch, on a 30-minute schedule, and on `workflow_dispatch`. It installs a pinned kendex, runs `kendex refresh --scope project --yes --leave` and `kendex verify`, commits to the one rolling branch `kendex/refresh`, opens or updates one rolling pull request, and arms auto-merge with the lanes app token from organization secrets. The pull request is `render` class: no review, one CI job, then the queue. No overseer and no control-VM toolchain take part. kendex never pushes to a consumer.
   - A `render`-class pull request is outside the review gate by the class policy, objections included; KEN-1765 makes the class policy active by default. The refresh workflow resolves every automatic-review thread on its rolling pull request with one fixed reply naming the class and this rule, so conversation resolution holds. Each run also reads the automatic-review threads on the last merged `kendex/refresh` pull request and resolves and files them the same way, so a thread posted after the merge is not lost. A thread that names a defect in a rendered file is filed upstream against kendex and never fixed on the rolling pull request.
3. **Organization rulesets.** Rulesets are organization rulesets that target all repositories. The default branch requires the merge queue, the required checks `Review gate` and one aggregate context `CI`, conversation resolution, and a Copilot review request, which holds no merge, with zero bypass actors. Per-repository rulesets are deleted once the organization rulesets stand. A new repository inherits everything on adoption, plus the app installation. Settings are set once at the organization level, never per repository. The GitHub apps act; no step swaps one token for another.

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

- Each retired item and the issue that retires it:

| Retired | Where it lives today | Issue |
| --- | --- | --- |
| The overseer's admin verb | `skills/orch/workflows/merge-pr-admin.md`, `pr-merge --admin-credential` | KEN-1777 |
| `ORCH_ADMIN_MERGE_GH_CONFIG_DIR` | `kendex.settings.toml`, `skills/github/scripts/commands/pr-merge.sh` | KEN-1777 |
| `ORCH_ADMIN_MERGE_CLASSES` | `kendex.settings.toml`, `skills/github/scripts/commands/pr-merge.sh` | KEN-1777 |
| `ORCH_MERGE_BYPASS` and its fast path | `kendex.settings.toml`, `skills/orch/workflows/merge-pr.md` | KEN-1777 |
| The merge-ready ask | `skills/orch/workflows/merge-pr-admin.md`, `skills/orch/references/oversee-events.md` § Admin merges | KEN-1777 |
| The `vanillagreen-merge-rail` app | the organization's app installations and the ruleset bypass list; nothing in this repository references it | KEN-1777 |
| `consumer-train.md` and its manual steps | `skills/orch/workflows/consumer-train.md` | KEN-1779 |
| `ORCH_CONSUMER_REPOS` | `skills/orch/workflows/consumer-train.md`, `skills/orch/kendex.settings.toml.example` | KEN-1779 |
| The create-time sandbox refresh | `kendex update-pi` and `kendex refresh` in `skills/orch/scripts/lane-host-ssh` create, `skills/orch/schemas/lane-host.md` | KEN-1780 |
| Each per-repository ruleset, kendex's merge-queue ruleset 20569265 among them, with its bypass actors | each repository's ruleset settings in GitHub; nothing in this repository | KEN-1778, as the owner action after it lands in every repository |

- KEN-1777 rewrites [../architecture/merge-rail.md](../architecture/merge-rail.md) § Ownership, § Boundaries and § Decisions to this decision's end state.
- Each repository reports one aggregate required context `CI` beside `Review gate`, and `merge_group` classifies through the same class job set (KEN-1778).
- A lane's worktree comes from a current `main` (KEN-1780).
- A review-gate validation reports, read-only, whether a repository's rulesets, required contexts, app installation and organization secrets match this decision, and `kendex check` relays its verdict (KEN-1781).
- The kendex app and CLI open no pull request in a consumer; [../architecture/overview.md](../architecture/overview.md) § Decisions states it.

**Revisit When**: GitHub organization rulesets or the merge queue are unavailable to a repository kendex must serve; a consumer cannot run GitHub Actions or read organization secrets; or a queue run for a `render` or `trivial` group costs more time than the direct merge it replaced.

**Verification**: KEN-1781's validation, once it lands, run under a lanes app installation token with repository administration read. The lane token lacks that permission and reads the bypass-actor list as empty. Until then, the owner reads the organization ruleset settings in GitHub: zero bypass actors, the merge queue and the two required contexts.

**References**: KEN-1776, KEN-1646, KEN-1672, KEN-1750, KEN-1765, KEN-1777, KEN-1778, KEN-1779, KEN-1780, KEN-1781; superseded: KEN-1601, KEN-1602
