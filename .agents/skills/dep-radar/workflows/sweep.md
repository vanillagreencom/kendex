# Sweep dependencies

Run when performing a dependency sweep. Read the [operating policy](../SKILL.md#operating-policy-the-contract-with-the-product-owner), [technology playbooks](../SKILL.md#technology-playbooks) and [guardrails](../SKILL.md#guardrails) before the sweep.

## Phase 0: inventory (self-maintaining)

`docs/dep-radar/inventory.md` carries one row per pinned surface: pin location, upstream check command, refresh procedure, verify command, risk tier, applicable playbook, and any repo-specific owner rules.

**First run** (no inventory): sweep the repo for pins in package manifests and lockfiles, `vendor/` dirs, SHA-256 constants near download or pin code, model manifest scripts, and version constants referencing upstream releases. Write the inventory, wire an upstream check per surface, and have the owner review the tiers.

**Every run**: diff discovered pins against the inventory, add new surfaces (each with a check), drop removed ones, and note the change in the run report.

## Phase 1: detect

Read `docs/dep-radar/last-seen.json` (create if absent) and run each surface's upstream check. If nothing moved since last-seen, update `checked_at`, write a one-line report, and stop.

## Phase 2: research

For each changed surface, read the changelog or release notes, never infer from version numbers. Extract breaking changes, deprecations, security fixes, new capabilities, and anything touching a contract the inventory names for that surface.

## Phase 3: classify

Sort every finding per the operating policy plus the inventory's per-surface tier and owner rules.

## Phase 4: apply the auto tier

Apply the inventory's refresh procedure, then fix the fallout in that surface's PR: migrate changed APIs, re-vendor bundled-extension bridges, repair broken tests and CI. Run the verify command; open the PR only once it passes locally, following the repo's review and merge-queue conventions. PR body: old→new version, changelog summary with links, fallout fixed, what was verified.

A blocker mid-apply or a failed verification stops the surface and makes it a report item with the exact error output, never ship a partial bump.

## Phase 5: report

Update `docs/dep-radar/last-seen.json` with each checked surface's observed version and `checked_at`. Commit that state and any Phase 0 inventory changes through the repository's existing review and merge route.

Write `tmp/dep-radar/report-<YYYY-MM-DD>.md`: auto-applied bumps with PR links; blocked bumps with exact error output; the owner-decision tier; new capabilities unlocked. Attach the report to the work item the run serves and cite it in the PR description or handoff. With no work item, give the owner the report through the current session. Do not commit dated reports under `docs/dep-radar/`. Each awaiting-decision item names the capability, what it unlocks, estimated effort and risk, and a recommendation.
