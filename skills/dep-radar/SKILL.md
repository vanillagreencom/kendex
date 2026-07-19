---
name: dep-radar
description: "Sweep every pinned version in the repo (SDKs, pinned runtime binaries, npm/cargo deps, vendored forks, model weights), check upstream, read changelogs, auto-apply safe bumps via one PR per surface, and report new-capability opportunities to the product owner. Self-maintains a per-repo inventory; run on a schedule/loop or on demand."
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

Repos pin versions deliberately (reproducibility, SHA verification, supply-chain
safety). The cost of pinning is drift: model lists lag pinned SDKs, pinned
runtime binaries fall behind upstream contract changes. This skill is the
refresh loop that makes pinning safe: **inventory → detect → research →
classify → auto-fix the safe tier → report the product tier**.

The skill is the generic engine; everything repo-specific lives in a per-repo
inventory that the skill itself generates and maintains (Phase 0). Nothing here
may be edited per-project — project differences (concrete package names, pinned
binaries, fork lists) belong only in the inventory file.

Load `github` before Phase 4 — all PR creation, CI status, and merge operations
go through it. Load `worktree` when applying more than one surface in a run, so
each surface's branch gets an isolated working copy.

## Operating policy (the contract with the product owner)

The contract, verbatim:

> AUTO-apply: security fixes; patch/minor bumps; pinned-binary version+SHA refreshes from OFFICIAL manifests only; SDK bumps with clean changelogs; internal improvements with no user-facing behavior change.
>
> REPORT (never auto): new user-facing capabilities; breaking/major bumps; vendored-fork rebases; model swaps.
>
> Uncertain → report.
>
> Every run ends with a dated report.
>
> Inventory owner-rules may demote auto→report, never promote report→auto.

Elaborated:

- **Auto-apply, no ask** — one PR per surface (never batch); merge only if all
  checks pass: security advisories; patch/minor bumps of routine deps;
  pinned-runtime-binary version+SHA refreshes sourced only from the official
  release manifest; SDK bumps whose changelog shows no breaking changes;
  internal code improvements a new version enables **when they change no
  user-facing behavior** (better API replacing a workaround, deprecation fixes).
- **Report, never auto-apply**: new user-facing capabilities a bump unlocks
  (e.g. new provider models a pinned AI SDK exposes); major/breaking bumps;
  vendored-fork rebases; model-weight swaps; anything the inventory marks as an
  owner decision (repos add their own rules there — e.g. data-scope changes).
- When uncertain, classify as report — a deferred bump is recoverable; a bad
  auto-merge is not.
- Every run ends with a dated report even when nothing was applied.
- Inventory owner rules override the generic tiers in the report direction
  only: a rule can demote auto→report, never promote report→auto.

## Phase 0 — inventory (self-maintaining)

The per-repo inventory lives at `docs/dep-radar/inventory.md`: a table of every
pinned surface with — pin location, upstream check command, refresh procedure,
verify command, risk tier (auto / report), applicable playbook, and any
repo-specific owner rules.

- **First run** (no inventory): discover pins by sweeping the repo — package
  manifests + lockfiles, `vendor/` dirs, SHA-256 constants near download/pin
  code, model manifest scripts, version constants referencing upstream
  releases — then WRITE the inventory and have the owner glance at the tiers.
- **Every run**: diff discovered pins against the inventory; add new surfaces,
  drop removed ones, and note the change in the run report.

## Phase 1 — detect (cheap; makes scheduled runs nearly free)

Read `docs/dep-radar/last-seen.json` (create if absent). Query upstream latest
for each surface. If nothing changed since last-seen, update `checked_at`,
write a one-line report, and stop — an idle run should cost a few registry
calls, not a build. (Skip-if-unchanged, same principle as tiered-CI nightlies.)

## Phase 2 — research

For each changed surface, read the actual changelog/release notes online —
never guess from version numbers. Extract: breaking changes, deprecations,
security fixes, new capabilities, and anything touching contracts the repo
depends on (the inventory names these per surface — e.g. an OAuth flow, an
RPC protocol, a model catalog).

## Phase 3 — classify

Sort every finding into **auto** / **report** per the policy plus the
inventory's per-surface tier and owner rules.

## Phase 4 — apply the auto tier

One branch + PR **per surface** (never batch surfaces — keeps reverts
surgical). Apply the inventory's refresh procedure, run its verify command,
and only open the PR when verification passes locally. PR body: old→new
version, changelog summary with links, what was verified. Use the `github`
skill for PR creation, CI waits, and merge; respect the repo's
review/merge-queue conventions.

Internal-improvement pass (bounded): if the changelog shows a better way to do
something the codebase already does, implement it in the same PR when small or
a follow-up PR when not. No user-facing behavior changes in this tier.

## Phase 5 — report

Write `docs/dep-radar/report-<YYYY-MM-DD>.md` (committed with the last-seen
update): what was auto-applied (PR links), and what awaits an owner decision —
each report item with the capability, what it would unlock, estimated
effort/risk, and a recommendation. Surface the report to the owner (PR
description / handoff doc), not just the file.

## Technology playbooks

Applied per surface by what the repo actually has (the inventory records which
apply). Concrete package, binary, and fork names live in the inventory, never
here.

- **Pinned AI/agent SDK** (a coding-agent or LLM SDK pinned by exact version):
  registry `latest` + release notes. New provider models exposed by a bump are
  the canonical report-tier item; a clean-changelog bump itself is auto-tier.
  Verify: build + test suites; confirm expected models/features appear.
- **Pinned runtime binary with SHA constants** (an app-managed runtime binary
  pinned by version plus per-platform SHA-256/size constants): version + SHAs
  refreshed **only from the official release manifest** for the exact version —
  never a third party, never hand-computed from a local download alone. Watch
  changelogs specifically for auth/protocol/contract changes. Verify: pin unit
  tests + a live download smoke on the host platform.
- **Routine npm/pnpm deps**: `pnpm -r outdated` and `pnpm audit`. Auto:
  patch/minor + all security. Report: major. Verify: typecheck + tests.
- **Routine cargo deps**: `cargo update --dry-run` and `cargo audit` (if
  installed). Same tiers. Verify: workspace tests with the repo's CI feature
  parity.
- **Vendored/patched upstream forks** (upstream projects vendored with local
  patches): upstream releases are report-only — rebasing local patches is
  owner-decided, never automatic.
- **Model weights / artifact SHA pins**: report-only; verify scripts exist in
  the repo, use them for integrity checks, never swap weights automatically.
- **Pinned GitHub Actions SHAs**: auto for patch/minor tag moves of the same
  action (refresh the SHA comment too); report for majors.

## Guardrails

- One PR per surface; never batch.
- If a bump's verification fails, do not ship a partial bump; report the
  failure with error output instead.
- Never auto-rebase vendored forks; never swap model weights automatically.
- Migration-bearing dep bumps (DB/storage tooling): check the repo's
  merge-order/version-gap hazards before merging.
- Honor every owner rule recorded in the inventory (these override the
  generic tiers in the report direction only — a rule can demote auto→report,
  never promote report→auto).
- Harness-safe shell: run upstream checks and verify commands as single simple
  commands — no loops, no command substitution, no composition — so runs
  survive restrictive harness approval policies.
