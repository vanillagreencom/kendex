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
  version: "1.0.0"
tags: [release]
---

# dep-radar: pinned-version sweep, safe auto-update, and capability report

**inventory → detect → research → classify → upgrade-with-fixes → report the
owner tier**.

Generic engine only: concrete package names, pinned binaries, and fork lists
live in the per-repo inventory, never here.

Load `github` before Phase 4 (PR creation, CI status, merges). Load `worktree`
when a run applies more than one surface, one working copy per surface branch.

## Operating policy (the contract with the product owner)

Each rule has a key. The key is the contract's handle: an inventory owner-rule
cites it. The wording in the second column may be edited; dropping or renaming
a key changes the contract.

| Rule | Contract |
|---|---|
| `auto-with-fixes` | The default. Security fixes; patch/minor bumps; pinned-binary version+SHA refreshes from OFFICIAL manifests only; SDK, agent-tooling, and runtime-binary bumps and npm/cargo majors, doing the bump AND fixing its fallout (API migrations, re-vendored bundled-extension bridges, tests, CI) in the SAME per-surface workstream; bundled-extension fork updates and local patch rebases when the consuming repo's full test suite gates the sync. |
| `report-never-auto` | Model-weight swaps; changes to durable/recorded data scope; anything an inventory owner-rule explicitly demotes. Nothing else is report-by-default. |
| `uncertain` | Attempt the upgrade; report only what actually failed, with error output. |
| `defer` | Only on a strong concrete blocker, never a generic "it's a major" risk. |
| `one-pr-per-surface` | One PR per surface; never batch surfaces. A surface's fallout fixes go in THAT surface's PR. |
| `upstream-check-required` | Every pinned surface must have a wired upstream check command; a surface lacking one is an inventory defect the run must fix. |
| `dated-report` | Every run ends with a dated report. |
| `demote-only` | Inventory owner-rules may demote auto→report, never promote report→auto. |

A blocker is something you actually hit (a dropped capability with no migration
path, a transitive that does not support the new version), never an anticipated
risk.

## Phase 0: inventory (self-maintaining)

`docs/dep-radar/inventory.md` carries one row per pinned surface: pin location,
upstream check command, refresh procedure, verify command, risk tier, applicable
playbook, and any repo-specific owner rules.

**First run** (no inventory): sweep the repo for pins in package manifests and
lockfiles, `vendor/` dirs, SHA-256 constants near download or pin code, model
manifest scripts, and version constants referencing upstream releases. Write
the inventory, wire an upstream check per surface, and have the owner review
the tiers.

**Every run**: diff discovered pins against the inventory, add new surfaces
(each with a check), drop removed ones, and note the change in the run report.

## Phase 1: detect

Read `docs/dep-radar/last-seen.json` (create if absent) and run each surface's
upstream check. If nothing moved since last-seen, update `checked_at`, write a
one-line report, and stop.

## Phase 2: research

For each changed surface, read the changelog or release notes, never infer
from version numbers. Extract breaking changes, deprecations, security fixes,
new capabilities, and anything touching a contract the inventory names for that
surface.

## Phase 3: classify

Sort every finding per the operating policy plus the inventory's per-surface
tier and owner rules.

## Phase 4: apply the auto tier

Apply the inventory's refresh procedure, then fix the fallout in that surface's
PR: migrate changed APIs, re-vendor bundled-extension bridges, repair broken
tests and CI. Run the verify command; open the PR only once it passes locally,
following the repo's review and merge-queue conventions. PR body: old→new
version, changelog summary with links, fallout fixed, what was verified.

A blocker mid-apply or a failed verification stops the surface and makes it a
report item with the exact error output, never ship a partial bump.

## Phase 5: report

Write `docs/dep-radar/report-<YYYY-MM-DD>.md`, committed with the last-seen
update: auto-applied bumps with PR links; blocked bumps with exact error output;
the owner-decision tier; new capabilities unlocked. Each awaiting-decision item
names the capability, what it unlocks, estimated effort and risk, and a
recommendation. Surface the report to the owner (PR description or handoff
doc), not just the file.

## Technology playbooks

The inventory records which apply and every concrete package, binary, and fork
name.

| Surface | Upstream check | Tier and handling | Verify |
|---|---|---|---|
| Pinned AI/agent SDK | Registry `latest` + release notes | Auto-with-fixes, majors included: migrate changed auth, runtime, and tooling APIs in the same PR. New provider models a bump exposes are report-tier; the bump itself ships. | Build + test suites; confirm expected models and features appear |
| Pinned runtime binary with SHA constants | Official release manifest for the exact version, never a third party, never hand-computed from a local download alone | Auto-with-fixes: migrate auth, protocol, and contract changes | Pin unit tests + a live download smoke on the host platform |
| npm/pnpm deps | `pnpm -r outdated`, `pnpm audit` | Auto-with-fixes, including majors: fix the mechanical fallout (renamed APIs, config, broken tests) in the same PR | Typecheck + tests |
| cargo deps | `cargo update --dry-run`, `cargo audit` when installed | Auto-with-fixes, including majors | Workspace tests at the repo's CI feature parity |
| Bundled-extension forks, a small upstream synced in by script, provenance tracked, local patches on top | The sync script's upstream ref | Auto-with-fixes **only when the consuming repo's full test suite gates the sync**: take the update, rebase the local patches, fix fallout in the same PR. | That full test suite plus the sync script's own checks |
| Patched vendor forks of large upstreams, with no script-gated sync | Upstream releases | Report, owner-decided | none |
| Model weights and artifact SHA pins | Upstream manifest | Report, never swap weights automatically | The repo's own integrity-verify scripts |
| Pinned GitHub Actions SHAs | Tag → SHA for the same action | Auto for patch/minor tag moves, refreshing the SHA comment too; majors auto-with-fixes, migrating the workflow in the same PR | Workflow run |

## Guardrails

- Migration-bearing dep bumps (DB or storage tooling) carry merge-order and
  version-gap hazards; check the repo's before merging.
- Shell commands follow orch SKILL.md § Harness-Safe Shell.
