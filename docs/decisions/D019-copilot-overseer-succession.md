# D019: An overseer's succession walks the stated preference, whatever harness the caller runs on

[← Decision Index](INDEX.md)

**Date**: 2026-10-02

**Status**: Active

**Research**: KEN-2490; the evidence read for this record is a comment on that issue

**Decision**: `ORCH_OVERSEER_PREFERENCE` is the one order for every caller harness, with the caller entry last and no harness-specific order in any script; a consumer that wants a Copilot overseer to stay on Copilot names a `copilot:<model>:<effort>` entry first, and a successor that changes harness is named on stdout and in one fleet-log row. A Copilot account is one monthly credit pool, judged by `lanes pick` on that pool, and an unmeasured pool is never room for a successor. The caller's own account is kept as the successor seat only where the account judge reads it `has-room`, at the context mark or at a death, and never at a rate or qualifying mark or a wall; an unmeasured or unreadable caller account goes through `lanes pick` like every other entry, in `walk_entries` of `oversee-succeed`. A Copilot successor's first turn is proved by the overseer context record written from `session.usage_info` as well as by its pane. Every refusal of a live succession writes one fleet-log row and one owner notice.

**Why**: The preference is the owner's model order; a harness-first rule would override it for every harness and put a model order into the scripts. Nothing established that an unmeasured account has room, and `lanes pick` is the one judge of account room for every entry alike, so its refusal is never overridden for the caller's own seat. A refusal that only prints to stderr reaches nobody when the overseer is unattended.

**Rejected**: The caller's own harness first: overrides the owner's ladder. The preference filtered to the caller's harness: removes the cross-harness move at a wall, which is how a one-account Copilot fleet still finds a successor.

**Revisit when**: The owner rules that harness continuity outranks the preference ladder, Copilot changes or removes `session.usage_info`, or a one-account Copilot fleet reaches its context mark with its one account unmeasured and no successor found.
