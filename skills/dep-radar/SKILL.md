---
name: dep-radar
description: "Load to run or tune a dependency sweep."
summary: "Sweeps every pinned version in the repo (deps, SDKs, vendored forks, model weights), checks upstream, and lands upgrades with their fallout in one PR per surface."
license: MIT
user-invocable: true
dependencies:
  required: [github]
  optional: [worktree]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [release]
---

# dep-radar

Generic engine only: concrete package names, pinned binaries, and fork lists live in the per-repo inventory, never here.

## Operating policy (the contract with the product owner)

Rule keys are the contract. An inventory owner-rule cites them. Dropping or renaming a key changes the contract.

- `auto-with-fixes`: the default tier. It covers:
  - security fixes;
  - patch and minor bumps;
  - pinned-binary version and SHA refreshes, from official manifests only;
  - SDK, agent-tooling and runtime-binary bumps, and npm and cargo majors. The run does the bump and fixes its fallout in the same per-surface workstream: API migrations, re-vendored bundled-extension bridges, tests and CI.
  - bundled-extension fork updates and local patch rebases, when the consuming repo's full test suite gates the sync.
- `report-never-auto`: model-weight swaps, changes to durable or recorded data scope, and anything an inventory owner-rule explicitly demotes. Nothing else is report-by-default.
- `uncertain`: attempt the upgrade. Report only what actually failed, with its error output.
- `defer`: only on a strong concrete blocker you actually hit, such as a dropped capability with no migration path or a transitive that does not support the new version. Never defer on a generic "it's a major" risk or any other anticipated one.
- `one-pr-per-surface`: one PR per surface. Never batch surfaces. A surface's fallout fixes go in that surface's PR.
- `upstream-check-required`: every pinned surface has a wired upstream check command. A surface without one is an inventory defect the run fixes.
- `dated-report`: every run ends with a dated report.
- `demote-only`: an inventory owner-rule may demote auto to report. It never promotes report to auto.

## Sweep

When running a dependency sweep, follow [workflows/sweep.md](workflows/sweep.md).

## Technology playbooks

The inventory records which playbooks apply.

| Surface | Upstream check | Tier | Verify |
|---|---|---|---|
| Pinned AI or agent SDK | Registry `latest` and release notes | `auto-with-fixes`, majors included | Build and test suites |
| Pinned runtime binary with SHA constants | The official release manifest for the exact version | `auto-with-fixes` | Pin unit tests and a live download smoke on the host platform |
| npm or pnpm deps | `pnpm -r outdated` and `pnpm audit` | `auto-with-fixes`, majors included | Typecheck and tests |
| cargo deps | `cargo update --dry-run` | `auto-with-fixes`, majors included | Workspace tests at the repo's CI feature parity |
| Bundled-extension fork: a small upstream synced in by script, with provenance tracked and local patches on top | The sync script's upstream ref | `auto-with-fixes`, under the gate below | The consuming repo's full test suite and the sync script's own checks |
| Patched vendor fork of a large upstream, with no script-gated sync | Upstream releases | Report, owner-decided | None |
| Model weights and artifact SHA pins | Upstream manifest | Report | The repo's own integrity-verify scripts |
| Pinned GitHub Actions SHAs | Tag to SHA for the same action | `auto-with-fixes`, majors included | Workflow run |

- **Pinned AI or agent SDK.** Migrate changed auth, runtime and tooling APIs in the same PR. New provider models a bump exposes are report tier. The bump itself ships. Verify also that the expected models and features appear.
- **Pinned runtime binary.** Never take the SHA from a third party. Never compute it by hand from a local download alone. Migrate auth, protocol and contract changes.
- **cargo deps.** Also run `cargo audit` when it is installed.
- **Bundled-extension fork.** The tier is `auto-with-fixes` only when the consuming repo's full test suite gates the sync. Take the update, rebase the local patches and fix the fallout in the same PR.
- **Pinned GitHub Actions SHAs.** A patch or minor tag move also refreshes the SHA comment. A major migrates the workflow in the same PR.

## Guardrails

- A migration-bearing dep bump (DB or storage tooling) carries merge-order and version-gap hazards. Check the repo's rules for both before merging.
- Shell commands follow orch SKILL.md § Harness-Safe Shell.
