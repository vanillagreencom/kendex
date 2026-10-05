# D020: Lane hosts are host kinds that declare capabilities, and lanes pick spends the allowance that expires first

[← Decision Index](INDEX.md)

**Date**: 2026-10-02

**Status**: Active

**Research**: KEN-2589; the research report is attached to that issue and the design to KEN-2609

**Decision**: Each place a lane runs is a host kind: `local`, `ssh`, `claude-cloud` or `codex-cloud`; a managed cloud is a kind, not a lane-host provider. A kind declares its capabilities in one `lane-host capabilities` line, `launch`, `channel`, `files`, `status`, `stop`, `relaunch`, `park`, `accounts`, `pool` and `land`, each from a closed set, and every caller acts on a declared capability, never on a host or provider name. `open-terminal` stays the only launcher, the fleet lane record the only record, and `lanes pick` the only account pick. `lanes pick` spends the allowance that expires first: a grant that expires and does not refill before a refilling window, and a refilling window before a balance with no expiry; reserved seats and the last-resort rank apply before the tier, and the tier does not change the harness order. The rule is stated once in `lanes --help` and judged once in the sort key of `lane_selection`.

**Why**: A cloud branch inside `open-terminal` beside the provider route would be a second launcher with its own copy of each rule. A tagged capability value lets each caller match exhaustively, where probing an exit status cannot tell an absent verb from a fault. Unspent room in a refilling window comes back at its reset; an expiring grant is lost whole.

**Rejected**: A managed cloud as a lane-host provider: it offers no SSH target, worktree path or file verbs, which the provider protocol needs.

**Revisit when**: A managed cloud offers SSH or file access into a session, a provider documents a status or stop interface for its sessions, or an allowance appears that both expires and refills.
