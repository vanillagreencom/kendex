# D020: Lane hosts are host kinds that declare capabilities, and the account judge spends the allowance that expires first

[← Decision Index](INDEX.md)

**Date**: 2026-10-02

**Status**: Active

**Research**: KEN-2589; the research report is attached to that issue and the design to KEN-2609

**Decision**: Each place a lane runs is a host kind: `local`, `ssh`, `claude-cloud` or `codex-cloud`; a managed cloud is a kind, not a lane-host provider. A kind declares its capabilities in one line its provider's `capabilities` verb prints (`orch-runtime host capabilities`), each from a closed set, and every caller acts on a declared capability, never on a host or provider name. The runtime's `launch-lane` operation stays the only launcher, the fleet lane record the only record, and agent-runtime's account judge (`agent-runtime accounts pick`) the only account pick. The judge spends the allowance that expires first: a grant that expires and does not refill before a refilling window, and a refilling window before a balance with no expiry; the last-resort rank applies before the tier, and a seat is ranked by the room it leaves after what it keeps for its controller, as any account is by its room. The rule is judged once, in the order key of a room row in agent-runtime's account judge (`skills/agent-runtime/runtime/src/accounts/mod.rs::pick`).

**Why**: A cloud branch inside the lane launch beside the provider route would be a second launcher with its own copy of each rule. A tagged capability value lets each caller match exhaustively, where probing an exit status cannot tell an absent verb from a fault. Unspent room in a refilling window comes back at its reset; an expiring grant is lost whole.

**Rejected**: A managed cloud as a lane-host provider: it offers no SSH target, worktree path or file verbs, which the provider protocol needs.

**Revisit when**: A managed cloud offers SSH or file access into a session, a provider documents a status or stop interface for its sessions, or an allowance appears that both expires and refills.
