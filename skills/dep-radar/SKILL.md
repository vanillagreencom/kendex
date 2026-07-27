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
tier**. The bias is toward upgrading — apply the bump and fix its fallout in
the same per-surface PR, deferring only on a strong concrete blocker.

The skill is the generic engine; everything repo-specific lives in a per-repo
inventory that the skill itself generates and maintains (Phase 0). Nothing here
may be edited per-project — project differences (concrete package names, pinned
binaries, fork lists) belong only in the inventory file.

Load `github` before Phase 4 — all PR creation, CI status, and merge operations
go through it. Load `worktree` when applying more than one surface in a run, so
each surface's branch gets an isolated working copy.

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

Fixability is the deciding test for a breaking major: investigate what it
breaks (Phase 2), then the question is only *can the fallout be fixed in this
PR?* Defer only on a specific, named obstacle you actually hit — an upstream
that dropped a capability the repo depends on with no migration path, a
required transitive that does not yet support the new version — never generic
"it's a major, might break" caution.

## Phase 0 — inventory (self-maintaining)

The per-repo inventory lives at `docs/dep-radar/inventory.md`: a table of every
pinned surface with — pin location, upstream check command, refresh procedure,
verify command, risk tier (auto / report), applicable playbook, and any
repo-specific owner rules. **Every row must carry a wired upstream check
command** — a surface with a blank or missing check is an inventory defect (Phase
1 skips it silently), so wire one before the run proceeds.

- **First run** (no inventory): discover pins by sweeping the repo — package
  manifests + lockfiles, `vendor/` dirs, SHA-256 constants near download/pin
  code, model manifest scripts, version constants referencing upstream
  releases — then WRITE the inventory, wiring an upstream check for each
  surface, and have the owner glance at the tiers.
- **Every run**: diff discovered pins against the inventory; add new surfaces
  (each with an upstream check), drop removed ones, and note the change in the
  run report.

## Phase 1 — detect (cheap; makes scheduled runs nearly free)

Read `docs/dep-radar/last-seen.json` (create if absent). Query upstream latest
for each surface via its inventory upstream check command. If a surface has no
check command, that is an inventory defect — wire it (per Phase 0) rather than
silently skipping the pin. If nothing changed since last-seen, update
`checked_at`, write a one-line report, and stop — an idle run should cost a few
registry calls, not a build.

## Phase 2 — research

For each changed surface, read the actual changelog/release notes online —
never guess from version numbers. Extract: breaking changes, deprecations,
security fixes, new capabilities, and anything touching contracts the repo
depends on (the inventory names these per surface — e.g. an OAuth flow, an
RPC protocol, a model catalog).

## Phase 3 — classify

Sort every finding into **auto** / **report** per the operating policy plus the
inventory's per-surface tier and owner rules. When uncertain, classify auto and
attempt it; a failed attempt becomes a report item carrying its error output.

## Phase 4 — apply the auto tier

One branch + PR **per surface** (never batch surfaces — keeps reverts
surgical). Apply the inventory's refresh procedure, then fix the bump's fallout
in the SAME per-surface PR: migrate changed APIs, re-vendor bundled-extension
bridges, and repair the tests and CI the bump breaks. Run the verify command,
and only open the PR when verification passes locally. "Same workstream" scopes
the fallout to this surface's PR — it never means folding another surface in.
PR body: old→new version, changelog summary with links, the fallout fixed, and
what was verified. Use the `github` skill for PR creation, CI waits, and merge;
respect the repo's review/merge-queue conventions.

If a bump hits a strong concrete blocker mid-apply (an unmigratable API break, a
transitive that does not support the new version) or its verification fails,
stop and make it a report item with the exact error output — do not ship a
partial bump.

## Phase 5 — report

Write `docs/dep-radar/report-<YYYY-MM-DD>.md` (committed with the last-seen
update): what was auto-applied (PR links); any bump that hit a strong concrete
blocker, with its exact error output; the narrow owner-decision tier
(model-weight swaps, data-scope changes, owner-rule demotions); and
new-capability opportunities a bump unlocked. Each awaiting-decision item lists
the capability, what it would unlock, estimated effort/risk, and a
recommendation. Surface the report to the owner (PR description / handoff doc),
not just the file.

## Technology playbooks

Applied per surface by what the repo actually has (the inventory records which
apply). Concrete package, binary, and fork names live in the inventory, never
here.

- **Pinned AI/agent SDK** (a coding-agent or LLM SDK pinned by exact version):
  registry `latest` + release notes. Auto-with-fixes including majors: do the
  bump and migrate the changed APIs (auth/runtime/tooling) in the same
  per-surface PR. New provider models a bump exposes are logged as report-tier
  opportunities, but the bump itself ships. Verify: build + test suites; confirm
  expected models/features appear.
- **Pinned runtime binary with SHA constants** (an app-managed runtime binary
  pinned by version plus per-platform SHA-256/size constants): version + SHAs
  refreshed **only from the official release manifest** for the exact version —
  never a third party, never hand-computed from a local download alone.
  Auto-with-fixes: when a changelog carries auth/protocol/contract changes,
  migrate the repo's use of them in the same PR rather than deferring. Verify:
  pin unit tests + a live download smoke on the host platform.
- **Routine npm/pnpm deps**: `pnpm -r outdated` and `pnpm audit`. Auto:
  patch/minor + all security. Majors are auto-with-fixes — do the bump and fix
  the mechanical fallout (renamed APIs, config, broken tests) in the same PR;
  defer only on a strong concrete blocker. Verify: typecheck + tests.
- **Routine cargo deps**: `cargo update --dry-run` and `cargo audit` (if
  installed). Same tiers — majors auto-with-fixes. Verify: workspace tests with
  the repo's CI feature parity.
- **Bundled-extension forks** (a small upstream synced into the repo by script,
  with tracked provenance and local patches on top — e.g. a bridge extension):
  auto-with-fixes when the consuming repo's **full test suite gates the sync**.
  Take the upstream-tracking update, rebase the local patches, and fix any
  fallout in the same per-surface PR; the gating suite is what makes this safe
  to automate. Verify: the repo's full test suite plus the sync script's own
  checks.
- **True patched vendor forks of large upstreams** (a large third-party project
  vendored with local patches, no script-gated sync): report-only — rebasing
  local patches onto a big upstream is owner-decided, never automatic.
- **Model weights / artifact SHA pins**: report-only; verify scripts exist in
  the repo, use them for integrity checks, never swap weights automatically.
- **Pinned GitHub Actions SHAs**: auto for patch/minor tag moves of the same
  action (refresh the SHA comment too); majors are auto-with-fixes — migrate the
  workflow to the new major in the same PR, deferring only on a concrete
  blocker.

## Guardrails

- Migration-bearing dep bumps (DB/storage tooling): check the repo's
  merge-order/version-gap hazards before merging.
- Harness-safe shell: run upstream checks and verify commands as single simple
  commands — no loops, no command substitution, no composition — so runs
  survive restrictive harness approval policies.
