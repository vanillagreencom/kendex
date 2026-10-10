# D008: Unbound Copilot classes inherit and every agent carries repository rules

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active

**Research**: KEN-1937

**Decision**: On Copilot an unbound model class resolves to no model, as `inherit` does, so the session's model runs the agent. A consumer `[model-bindings.copilot]` binding writes its native model selector for that class without a compatibility warning. An explicit per-agent model id passes through as written. No `reasoningEffort` is written. Every rendered Copilot agent carries `include-custom-instructions: true`, in `crates/core/src/render/agent/copilot.rs`. The class table itself is [D021](D021-runtime-model-classes.md).

**Why**: Copilot ranks an agent file's `model` above the launch's `--model`, so an automatic class pin would silently override the operator's choice. A consumer that binds a class explicitly chooses that its agents outrank the launch model. A Copilot subagent reads no `AGENTS.md` unless its file says so, and every kendex agent works under the repository's rules.

**Rejected**: Mapping unbound classes to Copilot's current Claude ids: still outranks the launch's model without a consumer choice, and an id the account lacks may not load. Writing the instructions flag for reviewer agents only: a per-agent flag is one more thing to keep in step.

**Revisit when**: Copilot changes the precedence of the launch's `--model` and the agent file's model, or a subagent with no `reasoningEffort` is measured running at Copilot's default effort rather than the session's.
