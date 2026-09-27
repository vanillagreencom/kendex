# D008: A Copilot agent file names no model for a tier and carries the repository's rules

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active

**Research**: —

**Applies to**: `crates/core/src/harness/models.rs::resolve_model`, `crates/core/src/render/agent/copilot.rs`, `docs/adapters/copilot.md`

## Context

Copilot CLI picks a custom agent's model in this order, highest first: the agent file's `model`, the launch's `--model`, `COPILOT_MODEL`, the `model` setting, the CLI default. That order is Copilot's [programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference); no kendex run has measured it. kendex rendered every tier alias (`fable`, `opus`, `sonnet`, `haiku`) as `model: auto`. So an agent with a tier ran on whatever Copilot's router chose, even when the operator launched the session on a named model. The owner's rule is that a custom agent's model never silently overrides the model and effort the owner selected.

A custom agent that Copilot starts as a subagent reads no AGENTS.md or CLAUDE.md unless its file carries `include-custom-instructions: true`, and the file's optional keys include `reasoningEffort`, both per Copilot's [CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference). Every kendex reviewer judges a diff against the repository's rules, and every other kendex agent works under them.

## Decision

1. Every tier resolves to no model on Copilot, as `inherit` already did, so the session's model runs the agent. An explicit model id still passes through as written.
2. No `reasoningEffort` is written, so an agent names no effort of its own.
3. Every rendered Copilot agent carries `include-custom-instructions: true`.

## Rationale

- Any id written for a tier outranks the launch's `--model`. `auto` hands the choice to Copilot's router. A pinned id names one model for every session, and Copilot fronts several vendors.
- Copilot's catalogue changes each month and depends on the plan, the organization's policy and `.github/allowed_models.txt`. A pinned id can also be absent from the account.
- Claude Code gives every subagent the project's CLAUDE.md. `include-custom-instructions` is the one way to give a Copilot subagent the same rules.

## Alternatives Considered

| Alternative | Why rejected |
| --- | --- |
| Keep `auto` for every tier | Copilot's router replaces the owner's model, which is the override the rule forbids. |
| Map tiers to the Claude ids in Copilot 1.0.88's `help config` list (`claude-fable-5.1`, `claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4.5`) | Still outranks the launch's model: an `opus` agent would run `claude-opus-5` in a session launched on a newer model. An id the account lacks may not load. |
| Inherit the heavy tiers only, as Pi does, and pin the light tiers | A light-tier pin is still a model the owner did not choose, and it can be weaker than the session's. |
| Write `include-custom-instructions: true` for the reviewer agents only | Every kendex agent needs the repository's rules, and a flag chosen per agent is one more thing to keep in step. |

**Revisit When**: Copilot ranks the launch's `--model` above the agent file's model, or a subagent with no `reasoningEffort` is measured running at Copilot's default effort rather than the session's.

**Verification**: `crates/core/src/harness/models.rs` test `tiers_stay_tiers_and_explicit_ids_pass_through`, `crates/core/src/render/agent/copilot.rs` test `frontmatter_names_the_agent_and_leaves_the_model_to_the_session`, and `crates/core/tests/copilot.rs` test `an_agent_installs_with_copilots_double_extension_and_toggles_by_rename`. On a host with a Copilot login, `tools/harness-smoke --only copilot` runs the `instruction:subagent` row, which passes only on an answer the subagent builds from the repository's instructions. Nothing measures a subagent's effort yet; the `agent:effort` row reads skipped and says so.

**References**: KEN-1937, [gemini-copilot-matrix.md](../adapters/gemini-copilot-matrix.md) § D12, [Copilot CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference), [Copilot CLI programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference)
