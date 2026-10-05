# D019: A Copilot overseer's succession walks the stated preference, keeps its own seat at the context mark, and proves the first turn from the context record

[← Decision Index](INDEX.md)

**Date**: 2026-10-02

**Status**: Active

**Research**: KEN-2490; the evidence read for this record is a comment on that issue

**Decision**: `ORCH_OVERSEER_PREFERENCE` stays the one order for every caller harness, with the caller entry last and no harness-specific order in any script; a consumer that wants a Copilot overseer to stay on Copilot names a `copilot:<model>:<effort>` entry first, and a successor that changes harness is named on stdout and in one fleet-log row. A Copilot account is one monthly credit pool, judged by `lanes pick` on that pool; an unmeasured pool is never room for a successor, except that at the context mark an entry of the caller's harness keeps the caller's own account when its headroom is unmeasured and no account with room is found, since the successor spends the pool the caller already spends. The caller's own account is a valid successor seat at the context mark and at a death, never at the headroom, rate or qualifying mark or a wall. A Copilot successor's first turn is proved by the overseer context record written under the successor's pane key from `session.usage_info`, as well as by its pane; Claude, Codex and Pi successors keep the pane reading. Every refusal of a live succession writes one fleet-log row and one owner notice. A fix reaches a consumer only through that consumer's own refresh, and the watch start reports `orch-behind` once when the orch skill has a newer version on its source.

**Why**: The preference is the owner's model order; a harness-first rule would override it for every harness and put a model order into the scripts. At the context mark the account is not the problem, so refusing a successor on an unmeasured caller account leaves the same session spending the same pool until Copilot compacts. The pane reading is a screen reading; the SDK's usage event is Copilot's documented per-model-call signal, and kendex already records it per pane. A refusal that only prints to stderr reaches nobody when the overseer is unattended.

**Rejected**: The caller's own harness first: overrides the owner's ladder. The preference filtered to the caller's harness: removes the cross-harness move at a wall, which is how a one-account Copilot fleet still finds a successor. A kendex job that refreshes a consumer: a refresh is the consumer's commit to make.

**Revisit when**: The owner rules that harness continuity outranks the preference ladder, Copilot changes or removes `session.usage_info`, a one-account Copilot fleet reaches its headroom mark with lanes still running, or a consumer restores an automatic refresh.
