# Dep Radar

Pinned-version sweep, safe auto-update, and capability reporting for repos
that pin dependencies deliberately (SDKs, runtime binaries with SHA constants,
npm/cargo deps, vendored forks, model weights, GitHub Actions).

Pinning buys reproducibility and supply-chain safety; the cost is drift.
Dep Radar is the refresh loop that makes pinning safe: it inventories every
pinned surface, detects upstream changes cheaply, reads the actual changelogs,
auto-applies the safe tier via one PR per surface, and reports everything that
deserves a product-owner decision.

## What it does

| Phase | Action |
|-------|--------|
| 0 — Inventory | Generates and maintains `docs/dep-radar/inventory.md` in your repo: every pinned surface with its pin location, upstream check, refresh procedure, verify command, and risk tier. |
| 1 — Detect | Compares upstream latest against `docs/dep-radar/last-seen.json`; unchanged surfaces cost a few registry calls and the run stops early. |
| 2 — Research | Reads real changelogs/release notes for each changed surface — never guesses from version numbers. |
| 3 — Classify | Sorts findings into auto vs. report per the policy and the inventory's owner rules. |
| 4 — Apply | Opens one PR per surface for the auto tier; verifies locally before opening; merges only when checks pass. |
| 5 — Report | Writes a dated report of what was applied and what awaits an owner decision, every run. |

## The policy contract

- **Auto-with-fixes** (one PR per surface, merged only when checks pass):
  security fixes; patch/minor bumps; pinned-binary version+SHA refreshes from
  official manifests only; and — the bias-to-upgrade default — SDK,
  agent-tooling, and runtime-binary bumps, npm/cargo majors, and
  bundled-extension fork syncs. For those the skill does the bump and fixes its
  fallout (API migrations, re-vendored bridges, tests, CI) in the same
  per-surface workstream, deferring only on a strong concrete blocker.
- **Reported, never auto-applied — exactly three things**: model-weight swaps;
  changes to durable/recorded data scope; and anything an inventory owner-rule
  explicitly demotes. Nothing else is report-by-default.
- Uncertain findings are attempted, not deferred: the skill tries the upgrade
  and reports only what actually failed, with error output.
- Every pinned surface must have a wired upstream check command; a surface
  without one is an inventory defect the run fixes.
- True patched vendor forks of large upstreams stay report-tier; a
  bundled-extension fork (script-synced, provenance-tracked) is auto-with-fixes
  when your full test suite gates the sync.
- Every run ends with a dated report, even an idle one.
- Your inventory's owner rules can make the skill more conservative
  (demote auto → report) but never less (a rule cannot promote report → auto).

## Repo-agnostic by design

The skill contains no project-specific content. Everything about *your* repo —
which packages are pinned where, how to refresh and verify each one, extra
owner rules — lives in `docs/dep-radar/inventory.md`, which the skill writes
on first run and keeps in sync on every run after.

## Setup

1. Install the `github` skill (required for the PR flow); add `worktree` if
   you want per-surface branch isolation when multiple bumps land in one run.
2. Invoke via your AI coding harness (e.g. `/dep-radar`), on demand or from a
   schedule/loop.
3. On first run, review the generated inventory's risk tiers.

No configuration keys are required.
