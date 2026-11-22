# D019: An overseer's succession walks the stated preference, whatever harness the caller runs on

[← Decision Index](INDEX.md)

**Date**: 2026-10-02

**Status**: Active (unmeasured-account exception → D037)

**Research**: KEN-2490; the evidence read for this record is a comment on that issue

**Decision**: `AGENT_RUNTIME_CONTROLLER_PREFERENCE` is the one order for every caller harness, with the caller entry last and no harness-specific order in any script; a consumer that wants a Copilot overseer to stay on Copilot names a `copilot:<model>:<effort>` entry first, and a successor that changes harness is named on stdout and in one fleet-log row. A Copilot account is one monthly credit pool, judged by agent-runtime's account judge (`agent-runtime accounts pick`) on that pool, and an unmeasured pool is never room for a successor, with one exception: at the context mark an entry of the caller's harness keeps the caller's own account when nothing measured it and that entry's pick finds no account with room, named `kept_unmeasured` in the walk's answer and in one fleet-log row. The caller's own account is otherwise kept as the successor seat only where the account judge reads it `has-room`, at the context mark or at a death, and never at a headroom, rate or qualifying mark or a wall; an unreadable judge keeps no account, and its entries go through the account judge like every other, in agent-runtime's preference walk (`accounts/walk.rs`). A Copilot successor is confirmed by its native session identity, the delivered brief recorded as a `user.message` in its `events.jsonl`, and its pane after that turn. This proof does not require an overseer context record from `session.usage_info`. Every refusal of a live succession writes one fleet-log row and one owner notice.

**Why**: The preference is the owner's model order; a harness-first rule would override it for every harness and put a model order into the scripts. agent-runtime's account judge is the one judge of account room for every entry alike; at the context mark the account is not the problem, since the successor spends the pool the caller already spends, so refusing on an unmeasured caller account protects none and leaves a person to hand over by hand. A refusal that only prints to stderr reaches nobody when the overseer is unattended.

**Rejected**: The caller's own harness first: overrides the owner's ladder. The preference filtered to the caller's harness: removes the cross-harness move at a wall, which is how a one-account Copilot fleet still finds a successor.

**Revisit when**: The owner rules that harness continuity outranks the preference ladder, or Copilot changes or removes `session.usage_info`.
