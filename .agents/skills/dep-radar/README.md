# Dep Radar

A dependency sweep for a repository: it inventories every pinned SDK, binary, package, fork, model weight and GitHub Action, checks upstream for releases, applies the safe bumps, and reports the rest. For a project owner who wants pins kept current without reading every changelog.

## Install

```bash
kendex add vanillagreencom/kendex --skill dep-radar
```

Needs the `github` skill for the PR flow. Add `worktree` when several bumps land in one run, one working copy per surface. Invoke it from your harness (`/dep-radar`), on demand or from a schedule.

## What it does

- Writes and maintains `docs/dep-radar/inventory.md`: every pinned surface with its pin location, upstream check, refresh procedure, verify command and risk tier.
- Compares upstream against `docs/dep-radar/last-seen.json`, so a run where nothing moved costs a few registry calls.
- Reads the real changelog for each surface that moved and classifies the change.
- Opens one PR per surface for the automatic tier, carrying the bump plus the fixes its fallout needs, verified locally first.
- Writes a dated report every run, with the bumps that need an owner decision.

## How it works

Nothing in the skill is project-specific. Everything about your repository lives in the inventory, which the skill writes on the first run and keeps in sync afterwards. Review the risk tiers in that first inventory; they decide what gets bumped without asking.

## Customise

- The inventory is the configuration: risk tiers, refresh procedures and owner rules are rows in `docs/dep-radar/inventory.md`. No settings keys.
