# Dep Radar

Dep Radar inventories pinned SDKs, binaries, packages, forks, model weights, and
GitHub Actions. It checks upstream releases, updates eligible pins with their
required fixes in one PR per surface, and writes a dated report for every run.

## How it works

The skill generates and maintains `docs/dep-radar/inventory.md` — every pinned
surface with its pin location, upstream check, refresh procedure, verify
command, and risk tier — then compares upstream against
`docs/dep-radar/last-seen.json`, so a run where nothing moved costs a few
registry calls and stops early. For each surface that did move it reads the real
changelog, classifies the change, and for the automatic tier opens one PR per
surface carrying the bump plus the fixes its fallout needs (API migrations,
re-vendored bridges, tests, CI), verified locally before the PR opens. Every run
ends with a dated report.

Nothing in the skill is project-specific. Everything about *your* repo — which
packages are pinned where, how to refresh and verify each one, extra owner
rules — lives in the inventory, which the skill writes on first run and keeps in
sync afterwards.

## Setup

Install the `github` skill, which the PR flow requires; add `worktree` for
per-surface branch isolation when several bumps land in one run. Invoke it from
your AI coding harness (`/dep-radar`), on demand or from a schedule. On the first
run, review the risk tiers in the generated inventory. No configuration keys are
needed.
