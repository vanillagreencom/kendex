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

- **Auto-applied** (one PR per surface, merged only when checks pass):
  security fixes; patch/minor bumps; pinned-binary version+SHA refreshes from
  official manifests only; SDK bumps with clean changelogs; internal
  improvements with no user-facing behavior change.
- **Reported, never auto-applied**: new user-facing capabilities; breaking or
  major bumps; vendored-fork rebases; model swaps.
- Uncertain findings are always reported, never auto-applied.
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
