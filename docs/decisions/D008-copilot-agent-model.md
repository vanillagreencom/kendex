# D008: A Copilot agent file names no model for a class and carries the repository's rules

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active

**Research**: KEN-1937

**Decision**: On Copilot every model class resolves to no model, as `inherit` does, so the session's model runs the agent; an explicit model id passes through as written. No `reasoningEffort` is written. Every rendered Copilot agent carries `include-custom-instructions: true`, in `crates/core/src/render/agent/copilot.rs`. The class table itself is [D021](D021-runtime-model-classes.md).

**Why**: Copilot ranks an agent file's `model` above the launch's `--model`, so any id written for a class silently overrides the model and effort the operator selected, which the owner's rule forbids. A Copilot subagent reads no `AGENTS.md` unless its file says so, and every kendex agent works under the repository's rules.

**Rejected**: Mapping classes to Copilot's current Claude ids: still outranks the launch's model, and an id the account lacks may not load. Writing the instructions flag for reviewer agents only: a per-agent flag is one more thing to keep in step.

**Revisit when**: Copilot ranks the launch's `--model` above the agent file's model, or a subagent with no `reasoningEffort` is measured running at Copilot's default effort rather than the session's.
