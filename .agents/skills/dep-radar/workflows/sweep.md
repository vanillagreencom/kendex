# Sweep dependencies

Run when performing a dependency sweep. Read the [operating policy](../SKILL.md#operating-policy-the-contract-with-the-product-owner), [technology playbooks](../SKILL.md#technology-playbooks) and [guardrails](../SKILL.md#guardrails) before the sweep.

## Phase 0: inventory

`docs/dep-radar/inventory.md` carries one row per pinned surface: pin location, upstream check command, refresh procedure, verify command, risk tier, applicable playbook, and any repo-specific owner rules.

On the first run, with no inventory:

1. Sweep the repo for pins in package manifests and lockfiles, `vendor/` dirs, SHA-256 constants near download or pin code, model manifest scripts, and version constants referencing upstream releases.
2. Write the inventory.
3. Wire an upstream check per surface.
4. Have the owner review the tiers.

On every run:

1. Diff the discovered pins against the inventory.
2. Add new surfaces.
3. Drop removed ones.
4. Note the change in the run report.

## Phase 1: detect

1. Read `tmp/dep-radar/last-seen.json`. Create it if absent.
2. Run each surface's upstream check.
3. If nothing moved since last-seen, update `checked_at`, write a one-line report, and stop.

## Phase 2: research

For each changed surface:

1. Read the changelog or release notes. Never infer changes from version numbers.
2. Extract breaking changes, deprecations, security fixes, new capabilities, and anything touching a contract the inventory names for that surface.

## Phase 3: classify

Sort every finding per the operating policy plus the inventory's per-surface tier and owner rules.

## Phase 4: apply the auto tier

1. Load `github` before the first PR creation, CI status read or merge.
2. If the run applies more than one surface, load `worktree`, and use one working copy per surface branch.

For each auto-tier surface:

1. Apply the inventory's refresh procedure.
2. Fix the fallout in that surface's PR: migrate changed APIs, re-vendor bundled-extension bridges, repair broken tests and CI.
3. Run the verify command.
4. Open the PR only once the verify command passes locally. Follow the repo's review and merge-queue conventions.
5. Write the PR body: old→new version, changelog summary with links, fallout fixed, and what was verified.

If a blocker hits mid-apply or verification fails, stop the surface. Make it a report item with the exact error output. Never ship a partial bump.

## Phase 5: report

1. Update `tmp/dep-radar/last-seen.json` with each checked surface's observed version and `checked_at`. Keep these observations uncommitted.
2. Submit any Phase 0 declarative inventory changes through the repository's existing review and merge route.
3. Write `tmp/dep-radar/report-<YYYY-MM-DD>.md`: auto-applied bumps with PR links, blocked bumps with exact error output, the owner-decision tier, and new capabilities unlocked.
4. Attach the report to the work item the run serves. Cite it in the PR description or handoff.
5. With no work item, give the owner the report through the current session.

Do not commit dated reports under `docs/dep-radar/`. Each awaiting-decision item in the report names the capability, what it unlocks, estimated effort and risk, and a recommendation.
