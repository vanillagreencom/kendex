# D020: Lane hosts are host kinds that declare capabilities, and lanes pick spends the allowance that expires first

[← Decision Index](INDEX.md)

**Date**: 2026-10-02

**Status**: Active

**Research**: [KEN-2589 research report](../plans/claude-cloud-launch-research.md)

**Approval**: owner note 1790967939 directs the design and this record. No `authority.md` exists. The build waits for the owner's approval of [the design](../plans/lane-host-kinds.md).

**Applies to**: `skills/orch/schemas/lane-host.md`, `skills/orch/scripts/lane-host`, `skills/orch/scripts/lane-host-ssh`, `skills/orch/scripts/open-terminal`, `skills/orch/scripts/oversee-watch`, `skills/orch/scripts/lib/oversee-watch-text.sh`, `skills/orch/scripts/lane-mail`, `skills/orch/scripts/lane-close`, `skills/orch/scripts/lanes`, `skills/orch/scripts/lib/lane-model.sh`, `skills/orch/scripts/lib/lane-usage.sh`, `skills/orch/scripts/lib/lane-launch.sh`, `skills/orch/references/skill-rules.md`, `skills/orch/references/oversee-lanes.md`, `skills/orch/references/oversee-events.md`

**Context**: Lanes run in local tmux, on SSH hosts (static and Daytona) and in managed agent clouds (Claude Code cloud, Codex cloud). The provider protocol needs an SSH target, a worktree path and file verbs, and a managed cloud offers none of them. vgs and vsys start Claude cloud sessions by hand, which no lane record, `lanes pick` or `oversee-watch` sees. Claude cloud credit on 11 accounts expires at 2026-11-05T07:59Z, and on 2claude at its lapse on 2026-10-08.

**Decision**:

1. Each place a lane runs is a host kind: `local`, `ssh`, `claude-cloud` or `codex-cloud`. A managed cloud is a kind, not a lane-host provider.
2. A kind declares its capabilities in one `lane-host capabilities` line: `launch`, `channel`, `files`, `status`, `stop`, `relaunch`, `park`, `accounts`, `pool` and `land`, each from a closed set of values. The dispatcher answers for the kinds kendex owns. A provider answers for an `ssh` kind.
3. Every caller acts on a declared capability, never on a host or provider name. The declaration replaces absent-verb probing. The `park` and `accounts` probes go when fleet's Daytona provider declares its line.
4. `open-terminal` stays the only launcher, the fleet lane record the only record, and `lanes pick` the only account pick.
5. Expires-first: `lanes pick` spends the allowance that expires first. A grant that expires and does not refill (tier 0, earliest expiry first) comes before a refilling window (tier 1, ordered by `selection_score`), and a refilling window comes before a balance with no expiry (tier 2). The rule is stated once, in `lanes --help` § pick, and judged once, in the sort key of `lane_selection`. Its authority is owner note 1790967939 and this record. Reserved seats and the last-resort rank apply before the tier, and the tier does not change the harness order (owner note 1790974374; [the design](../plans/lane-host-kinds.md#other-pick-rules-beside-the-tier-key) § Other pick rules beside the tier key).

**Rationale**:

- A cloud branch inside `open-terminal` beside the provider route would be a second launcher in all but name, with its own copy of each rule.
- A tagged capability value per question lets each caller match exhaustively. Probing an exit status cannot tell an absent verb from a fault.
- Unspent room in a refilling window comes back at its reset. An expiring grant is lost whole, and a balance with no expiry loses nothing by waiting. KEN-2494's order folds into the same key ([the design](../plans/lane-host-kinds.md#the-expires-first-rule) § The expires-first rule).

**Revisit When**: a managed cloud offers SSH or file access into a session, a provider documents a status or stop interface for its sessions, or an allowance appears that both expires and refills.

**Verification**: the first build's acceptance test in [the design](../plans/lane-host-kinds.md) § The smallest first build, and a must-fail control on the tier key in the `lanes` suite.

**References**: KEN-2589, KEN-1553, KEN-2494, [D002](D002-hosted-launch-handoff.md), [D003](D003-one-merge-path.md), [D018](D018-platform-review-requirements.md)
