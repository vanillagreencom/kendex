# Dep Radar

Pinned-version sweep, safe auto-update, and capability reporting for repos that
pin dependencies deliberately — SDKs, runtime binaries with SHA constants, npm
and cargo deps, vendored forks, model weights, GitHub Actions. Pinning buys
reproducibility and supply-chain safety; the cost is drift. Dep Radar is the
refresh loop that keeps the pins current without giving up the control that made
them pins in the first place.

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

The bias is to upgrade: majors are applied with their fallout fixed rather than
deferred, and an uncertain finding is attempted rather than punted — the run
reports only what actually failed, with the error output. Exactly three things
are never automatic: model-weight swaps, changes to durable or recorded data
scope, and anything your inventory's owner rules demote. Those rules can make a
run more conservative, never less.

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
