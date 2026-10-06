# D003: Consumers pull renders through their own Actions runner, under organization rulesets

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active (merge path → D013, break-glass → D016, review requirements → D018)

**Research**: KEN-1776; the consumer refresh design is attached to KEN-2601

**Decision**: Each consumer's `.github/workflows/kendex-refresh.yml` calls kendex's shared workflow `.github/workflows/refresh-consumer.yml` at a major tag, on a dispatch from kendex `main`, on a schedule and by hand. Each run installs the release that tag names, runs `kendex refresh --scope project` and `kendex verify --scope project`, commits to the one rolling branch `kendex/refresh`, opens or updates one rolling pull request and arms auto-merge. The run's token is minted from the `kendex` environment's app secrets, mapped by name and never `secrets: inherit`; the environment admits the default branch only. kendex itself is excluded from consumer refresh under [D007](D007-lock-record-on-main.md). Branch rules are organization rulesets targeting every repository, beside the two repository rulesets [D013](D013-admin-merge-green-prs.md) adds: required checks and the merge queue. The merge route itself is [D013](D013-admin-merge-green-prs.md) and [D016](D016-merge-route-reads-bypass.md), and the review requirements [D018](D018-platform-review-requirements.md).

**Why**: A consumer's own runner does the refresh, so propagation costs the control VM nothing and kendex never pushes to a consumer. An organization secret would be readable by any branch workflow of every repository; an environment bound to the default branch is not. Per-repository rulesets each drift on their own.

**Rejected**: kendex pushing to consumers from the control VM: it loads the VM for up to half an hour per train and needs a write credential per consumer.

**Revisit when**: Organization rulesets are unavailable to a repository kendex must serve, or a consumer cannot run GitHub Actions or obtain its repository-scoped token.
