# D019: An overseer's succession walks the stated preference, whatever harness the caller runs on

[← Decision Index](INDEX.md)

**Date**: 2026-10-02

**Status**: Active

**Research**: KEN-2490; the evidence read for this record is a comment on that issue

**Decision**: `ORCH_OVERSEER_PREFERENCE` is the one order for every caller harness, with the caller entry last and no harness-specific order in any script; a consumer that wants a Copilot overseer to stay on Copilot names a `copilot:<model>:<effort>` entry first, and a successor that changes harness is named on stdout and in one fleet-log row. A Copilot account is one monthly credit pool, judged by `lanes pick` on that pool; an unmeasured pool is never room for a successor, except that at the context mark an entry of the caller's harness keeps the caller's own account, since the successor spends the pool the caller already spends. The caller's own account is a valid successor seat at the context mark and at a death, never at the headroom, rate or qualifying mark or a wall. A Copilot successor's first turn is proved by the overseer context record written from `session.usage_info` as well as by its pane. Every refusal of a live succession writes one fleet-log row and one owner notice.

**Why**: The preference is the owner's model order; a harness-first rule would override it for every harness and put a model order into the scripts. At the context mark the account is not the problem, so refusing a successor on an unmeasured caller account leaves the same session spending the same pool until Copilot compacts. A refusal that only prints to stderr reaches nobody when the overseer is unattended.

**Rejected**: The caller's own harness first: overrides the owner's ladder. The preference filtered to the caller's harness: removes the cross-harness move at a wall, which is how a one-account Copilot fleet still finds a successor.

**Revisit when**: The owner rules that harness continuity outranks the preference ladder, Copilot changes or removes `session.usage_info`, or a one-account Copilot fleet reaches its headroom mark with lanes still running.
