# Dep Radar

A dependency review workflow for repository maintainers. It checks pinned packages and tools for updates, applies permitted changes and reports changes that need your decision.

## Install

```bash
kendex add vanillagreencom/kendex --skill dep-radar
```

kendex also installs the github skill. Add worktree when a run needs separate working copies for several updates. Invoke `/dep-radar` in your coding tool.

## Features

- Maintain an inventory of pinned dependencies and update procedures.
- Check upstream releases and read their release notes.
- Create a separate PR for each dependency update and its required fixes.
- Write a report of applied updates and unresolved decisions.

## How it works

The agent reads the dependency inventory and checks for upstream releases. It compares the results with the last recorded check. For each update, it applies the inventory's approval rule. It tests permitted updates and opens their PRs. It records the results in a dated report.

## Settings

- The inventory is the configuration: risk tiers, refresh procedures and owner rules are rows in `docs/dep-radar/inventory.md`. No settings keys.
