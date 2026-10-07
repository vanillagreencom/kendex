# D023: Consumer refresh approval follows render proof

[← Decision Index](INDEX.md)

**Date**: 2026-10-07

**Status**: Active

**Research**: [KEN-3338](https://linear.app/vanillagreen/issue/KEN-3338)

**Applies to**: Pull requests authored by `vanillagreen-fleet-lanes[bot]` on the exact head branch `kendex/refresh`, with passing real render proof.

**Supersedes**: [D018](D018-platform-review-requirements.md) only for this scope. D018 remains binding for every other pull request.

**Decision**: The overseer approves these heads through [Consumer refresh approval](../../skills/orch/references/copilot-head-notices.md#consumer-refresh-approval). That route requires no internal agent review, GitHub agent review or Copilot wait.

**Why**: Catalog review already covers the rendered packages. A proved render adds no consumer product change to review.

**Rejected**: Repeat internal agent and Copilot reviews for proved renders. This repeats catalog review and spends review time without consumer product changes to assess.

**Revisit when**: Render proof admits consumer product changes, or refreshed packages no longer receive catalog review.
