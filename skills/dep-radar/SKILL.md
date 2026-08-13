---
name: dep-radar
description: "Sweep every pinned version in the repo (SDKs, pinned runtime binaries, npm/cargo deps, vendored forks, model weights), check upstream, read changelogs, and bias to upgrade — apply bumps (majors included) with their fallout fixed in the same per-surface PR, deferring only on a strong concrete blocker. Reports the narrow owner-decision tier (model-weight swaps, data-scope changes) and new-capability opportunities. Self-maintains a per-repo inventory; run on a schedule/loop or on demand."
license: MIT
user-invocable: true
dependencies:
  required: [github]
  optional: [worktree]
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# dep-radar — pinned-version sweep, safe auto-update, and capability report

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

The refresh loop that keeps deliberate version pinning current: **inventory →
detect → research → classify → upgrade-with-fixes → report the narrow owner
tier**.

This skill is the generic engine. Everything repo-specific — concrete package
names, pinned binaries, fork lists — lives in the per-repo inventory the skill
generates and maintains, never here.

Load `github` before Phase 4: PR creation, CI status, and merges all go through
it. Load `worktree` when a run applies more than one surface, so each surface's
branch gets an isolated working copy.

## Operating policy (the contract with the product owner)

> AUTO-with-fixes (default): security fixes; patch/minor bumps; pinned-binary version+SHA refreshes from OFFICIAL manifests only; SDK, agent-tooling, and runtime-binary bumps and npm/cargo majors, doing the bump AND fixing its fallout (API migrations, re-vendored bundled-extension bridges, tests, CI) in the SAME per-surface workstream; bundled-extension fork updates and local patch rebases when the consuming repo's full test suite gates the sync.
>
> REPORT (never auto): model-weight swaps; changes to durable/recorded data scope; anything an inventory owner-rule explicitly demotes. Nothing else is report-by-default.
>
> Uncertain → attempt the upgrade; report only what actually failed, with error output.
>
> Defer only on a strong concrete blocker, never a generic "it's a major" risk.
>
> One PR per surface; never batch surfaces — a surface's fallout fixes go in THAT surface's PR.
>
> Every pinned surface must have a wired upstream check command; a surface lacking one is an inventory defect the run must fix.
>
> Every run ends with a dated report.
>
> Inventory owner-rules may demote auto→report, never promote report→auto.

A blocker is something you actually hit — an upstream that dropped a capability
the repo depends on with no migration path, a required transitive that does not
support the new version — never a generic risk you anticipate.

## Phase 0 — inventory (self-maintaining)

`docs/dep-radar/inventory.md` carries one row per pinned surface: pin location,
upstream check command, refresh procedure, verify command, risk tier, applicable
playbook, and any repo-specific owner rules.

**First run** (no inventory): discover pins by sweeping the repo — package
manifests and lockfiles, `vendor/` dirs, SHA-256 constants near download or pin
code, model manifest scripts, version constants referencing upstream releases —
then write the inventory, wire an upstream check for each surface, and have the
owner glance at the tiers.

**Every run**: diff discovered pins against the inventory, add new surfaces
(each with a check), drop removed ones, and note the change in the run report.

## Phase 1 — detect

Read `docs/dep-radar/last-seen.json` (create if absent) and query each surface's
upstream check for the latest version. If nothing moved since last-seen, update
`checked_at`, write a one-line report, and stop: an idle run should cost a few
registry calls, not a build.

## Phase 2 — research

For each changed surface, read the actual changelog or release notes online —
never infer from version numbers. Extract breaking changes, deprecations,
security fixes, new capabilities, and anything touching a contract the repo
depends on (the inventory names those per surface — an OAuth flow, an RPC
protocol, a model catalog).

## Phase 3 — classify

Sort every finding per the operating policy plus the inventory's per-surface
tier and owner rules.

## Phase 4 — apply the auto tier

Apply the inventory's refresh procedure, then fix the bump's fallout in that
surface's PR: migrate changed APIs, re-vendor bundled-extension bridges, repair
the tests and CI it breaks. Run the verify command, and open the PR only once
verification passes locally, respecting the repo's review and merge-queue
conventions. The PR body gives old→new version, a changelog summary with links,
the fallout fixed, and what was verified.

A blocker hit mid-apply, or a failed verification, stops the surface and makes
it a report item with the exact error output — never ship a partial bump.

## Phase 5 — report

Write `docs/dep-radar/report-<YYYY-MM-DD>.md`, committed with the last-seen
update: what was auto-applied, with PR links; any bump that hit a blocker, with
its exact error output; the owner-decision tier; and new capabilities a bump
unlocked. Each awaiting-decision item names the capability, what it would
unlock, estimated effort and risk, and a recommendation. Surface the report to
the owner — a PR description or handoff doc — not just the file.

## Technology playbooks

Applied by what the repo actually has; the inventory records which apply, and
every concrete package, binary, and fork name.

| Surface | Upstream check | Tier and handling | Verify |
|---|---|---|---|
| Pinned AI/agent SDK | Registry `latest` + release notes | Auto-with-fixes, majors included: migrate the changed auth, runtime, and tooling APIs in the same PR. New provider models a bump exposes are report-tier opportunities, but the bump itself ships. | Build + test suites; confirm expected models and features appear |
| Pinned runtime binary with SHA constants | Official release manifest for the exact version — never a third party, never hand-computed from a local download alone | Auto-with-fixes: migrate auth, protocol, and contract changes rather than deferring them | Pin unit tests + a live download smoke on the host platform |
| npm/pnpm deps | `pnpm -r outdated`, `pnpm audit` | Auto-with-fixes, including majors: fix the mechanical fallout (renamed APIs, config, broken tests) in the same PR | Typecheck + tests |
| cargo deps | `cargo update --dry-run`, `cargo audit` when installed | Auto-with-fixes, including majors | Workspace tests at the repo's CI feature parity |
| Bundled-extension forks — a small upstream synced in by script, provenance tracked, local patches on top | The sync script's upstream ref | Auto-with-fixes **only when the consuming repo's full test suite gates the sync**: take the update, rebase the local patches, fix fallout in the same PR. The gating suite is what makes this safe to automate. | That full test suite plus the sync script's own checks |
| Patched vendor forks of large upstreams, with no script-gated sync | Upstream releases | Report — rebasing local patches onto a big upstream is owner-decided | — |
| Model weights and artifact SHA pins | Upstream manifest | Report — never swap weights automatically | The repo's own integrity-verify scripts |
| Pinned GitHub Actions SHAs | Tag → SHA for the same action | Auto for patch/minor tag moves, refreshing the SHA comment too; majors auto-with-fixes, migrating the workflow in the same PR | Workflow run |

## Guardrails

- Migration-bearing dep bumps (DB or storage tooling) carry merge-order and
  version-gap hazards; check the repo's before merging.
- Shell commands follow orch SKILL.md § Harness-Safe Shell.
