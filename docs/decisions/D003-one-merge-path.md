# D003: One merge path through the merge queue, consumers pull renders, organization rulesets

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active (merge path → D013, break-glass → D016, review requirements → D018)

**Research**: KEN-1776; the consumer refresh design is attached to KEN-2601

**Supersedes**: parts of this record are superseded by [D013](D013-admin-merge-green-prs.md) (the zero-bypass merge path), [D016](D016-merge-route-reads-bypass.md) (the gate-repair break-glass) and [D018](D018-platform-review-requirements.md) (the required review status and the review-finding answer contract)

**Decision**: Every repository merges through its merge queue, armed by the lanes app `vanillagreen-fleet-lanes`, with no owner credential on the control VM. Consumers pull kendex renders: each consumer's `.github/workflows/kendex-refresh.yml` calls kendex's shared workflow `.github/workflows/refresh-consumer.yml` at a major tag, on a dispatch from kendex `main`, on a schedule and by hand; each run installs the release that tag names, runs `kendex refresh --scope project` and `kendex verify --scope project`, commits to the one rolling branch `kendex/refresh`, opens or updates one rolling pull request, and arms native auto-merge on every run that reaches publication. The run's token is minted from the `kendex` environment's `FLEET_GH_APP_ID` and `FLEET_GH_APP_PRIVATE_KEY`, which the caller maps to the called workflow by name, never `secrets: inherit`; the environment admits the default branch only, and the owner-run `provision-environment.sh` creates it in every repository. The lanes app never holds Administration or Environments write. The master session moves the major tag under the owner bypass when a release is published; a lane moves none. kendex itself is excluded from consumer refresh under [D007](D007-lock-record-on-main.md). Rulesets are organization rulesets targeting all repositories.

**Why**: A direct merge that bypasses the queue rebuilds every running queue group, and the queue puts the pull request on top of `main` itself, so nothing restacks. A consumer's own Actions runner does the refresh, so propagation costs the control VM nothing and kendex never pushes to a consumer. An organization secret would be readable by any branch workflow of every repository; an environment bound to the default branch is not.

**Rejected**: kendex pushing to consumers from the control VM: it loads the VM for up to half an hour per train, needs the overseer and a write credential per consumer. Per-repository rulesets: each drifts on its own.

**Revisit when**: Organization rulesets or the merge queue are unavailable to a repository kendex must serve, a consumer cannot run GitHub Actions or obtain its repository-scoped token, or a queue run for a `render` group costs more than the direct merge it replaced.
