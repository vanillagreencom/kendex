# D021: Resolve model classes through one availability-aware owner

[← Decision Index](INDEX.md)

**Date**: 2026-10-01

**Status**: Active

**Research**: [KEN-2466](https://linear.app/vanillagreen/issue/KEN-2466), official interface evidence in [model-class-resolution.md](../plans/model-class-resolution.md#sources-and-evidence)

**Applies to**: `crates/core/src/harness/models.rs`, its renderer callers, `crates/cli/src/commands/tier_model.rs`, orch model selection, the Claude model-resolution mod and Pi agent dispatch

**Refines**: [D008](D008-copilot-agent-model.md), [D015](D015-copilot-compaction-handoff.md)

## Integration status

P3 implements the core, CLI, render and Pi portions of this decision. P4 Claude callbacks and P5 lane, launcher and context consumers remain pending. The runtime boundary below specifies their required behavior. It does not claim completed native integration. KEN-2496 separately owns ladder defaults.

## Decision

kendex owns one class table and one resolver in `harness::models`.

- Replace the bare string rows of `TIERS` with typed rows named `top`, `standard`, `light` and `fast`.
- Keep `fable`, `opus`, `sonnet` and `haiku` as input aliases on those same rows. They do not form another ladder.
- Put Fable and GPT Astra in top. Put Opus and GPT Sol in standard. Put Sonnet and GPT Luna in light. Put GPT Terra in fast.
- Leave the Claude fast member absent until the owner admits a Haiku newer than 4.5. With confirmed model evidence, a Claude-only fast request selects light and emits one warning. Unknown access or capacity uses native default instead.
- Use an account's documented harness model list when available. Unknown model access or capacity selects the harness's own default/session model and emits one warning naming the unconfirmed class. Preserve the native default path even when it exposes no exact id. The shipped table is selection policy, not evidence of access.
- Pass Claude Code's documented family aliases to Claude Code. Do not turn `opus` or `sonnet` into versioned launch pins.
- Use Claude Code's native mod callbacks on v2.1.287 or later. `agent.spawn` resolves a declared child request before startup. `turn.step` resolves an explicit root class request before a model call. Both call the existing core CLI. The mod contains no class table.
- Resolve concrete ids from the latest available family member for list-based harnesses. The table supplies a preferred id only where a harness lacks a moving alias. Its preferred id must still have availability evidence.
- Extend the existing `kendex tier-model` command for runtime requests and JSON results. Shell and Pi callers supply evidence and consume the result. They do not copy the table or the fallback rule.
- Keep `inherit` distinct from every class. It keeps the selected parent model.
- Overseers, successors and item lanes request standard by default. GPT-6.1 Sol takes Astra's former default tasks. An item requests top only when a label or an overseer-set brief field names why that item needs it. Never derive the class from an estimate, workflow size or a generic risk category.
- Keep the top row, availability fallback, legacy aliases, exact requests and consumer class overrides. A top fallback is not a top default or an item promotion.
- KEN-2496 owns the default overseer ladder edit. P3 preserves current ladder values. P5 resolver integration remains pending.

The owner authorizes implementation of these amendments without another design read. The orchestrator posts the amended artifacts, records the ruling in the PR body and delegates the introduced core defect's correction in this branch.

## Constraints and enforcing paths

| Constraint | Enforcing path in the planned implementation |
| --- | --- |
| Any one provider, without a plan assumption | `models::resolve_model` restricts explicit candidates to the supplied consumer inventory. After named-class fallback it uses the consumer's available default, current model or sole available model. For an unclassified inventory without a default, it chooses the first available chat model in stable provider/id order and warns. Unknown access or capacity instead preserves the native default/session selection. |
| Select explicit candidates only with access evidence | `HarnessAdapter::detect` supplies installation evidence only. The existing `lanes::collect_lanes` and `host_account_records` supply account evidence. Documented model lists or active-session evidence supply model evidence. The Claude mod forwards those facts through `tier-model`. `resolve_model` never treats a failed read as permission to choose an unverified table member. A native default selection is distinct from an explicit candidate and needs no invented id. |
| Unknown model facts do not block launch | `models::resolve_model` returns a tagged `HarnessDefault` result. `lanes`, `ol_launch_flags`, `open-terminal`, Pi child preparation and Claude `agent.spawn`/`turn.step` encode that result through the harness's native default/session path. `lane_adapter_claude_window` retains unknown capacity without guessing. Model resolution refuses only a confirmed absence of any usable harness model. Actual account walls and integration errors remain separate. |
| Standard default and item-specific top reason | `oversee.md` Lane directive owns the item judgment. Its overseer writes `**Top model reason**: <reason>` in the existing item brief, copied from a reason-bearing label or set explicitly. Existing `lanes --model` and `tier-model --model` carry standard or the justified top request. Remove the unreleased `ModelClass::for_item(tier, risk)` mapping and the CLI's `--item-tier`/`--risk` path. The general parser still accepts explicit classes. No new reason protocol or risk vocabulary is needed. |
| One table and a one-line override | `Manifest.model_classes`, read by `manifest::file::load_current` and `parse_text`, replaces one class row with the selector in `model-classes.fast = "my-provider/my-model"`. The resolver validates availability after the override. |
| Follow a family without stale pins | The Claude projection returns a native alias. Its mod supplies the runtime decision through `agent.spawn` and `turn.step`. Codex uses `model/list`, Copilot uses SDK `listModels()`, and Pi uses `ModelRuntime.getAvailable()` or its extension context's registry. One core family matcher chooses the newest available id. |

Account usage windows do not prove per-model entitlement. Directory detection does not prove sign-in. The plan makes these limits explicit rather than inventing a probe.

## Fallback and compatibility

The class walk starts at the requested row. It visits lower rows in order, then higher rows from the nearest to the farthest. It visits each row once. For fast the order is fast, light, standard, top. For standard it is standard, light, fast, top. After the class walk, an unclassified available default is a final candidate. Unknown access or capacity stops explicit candidate selection and uses the harness's native default/session path. A complete empty list does not close that separate path. Model resolution refuses only when the harness has no usable model at all.

The existing account chooser still judges usage, claims and projected room from known facts. Known unavailable or walled candidates may advance the class walk. An absent list interface, unread model evidence and a complete empty inventory remain distinct states. Missing or failed model evidence produces the native-default result, not a new unverified class candidate. The single fallback warning retains the failed source and cause. Missing model capacity is not an account wall. A known account wall still blocks that account. Native default cannot re-admit a model confirmed denied or excluded by policy. Unrelated account and integration failures retain their own diagnostics.

A process emits at most one model-resolution warning line through its top-level render, pick or launch owner. The line names the requested class that could not be confirmed. It combines old-id, fallback, unclassified and unknown-access/capacity causes, including failed-source diagnostics. Nested callers carry structured diagnostics and print no second copy. A native-default result claims neither an exact id nor a capacity number when those facts are unknown.

Exact ids remain readable and remain exact when available and their capacity is confirmed where needed. They warn once. They do not turn into the newest family member. Unknown access or capacity for a pin uses the native default/session path with the original pin and cause in the warning. This does not claim that the pin is accessible. A pin confirmed unavailable remains an explicit `model-unavailable` error, not an unknown-evidence case. Confirmed exact Haiku 4.5 or earlier is the policy exception: core substitutes through fast fallback and emits one warning naming the substitution. Confirmed exact Haiku newer than 4.5 stays exact and emits one compatibility warning. Bare `haiku` remains the fast class alias. Fast has no Claude member. An override cannot re-enable a Haiku version at or below 4.5.

## Runtime boundary

A native moving alias can remain in a rendered file and reach native runtime selection. Claude Code also has a native runtime callback path. Its supported-build declarations allow `agent.spawn` to rewrite the model through `next({ ...e, model })` before child startup. Returning `{ model }` without `next` starts no child. A refusal returns `{ deny: reason }`. Its [events guide](https://code.claude.com/docs/en/plugins/mods/events#follow-a-turn) documents `turn.step` replacing the request model through `next({ ...e, model })`. These are function hooks inside the harness, not settings-file command hooks.

A Pi class can remain in Pi agent frontmatter because kendex owns the child dispatcher. The dispatcher resolves it before it starts the child. With kendex present, every request goes through core. With kendex missing, the dispatcher preserves native inherit and an exact model found in the authenticated Pi registry. It refuses all other requests with one resolver-missing diagnostic that names kendex as the fix. This bounded path does not parse classes or copy the model table.

Other native agent loaders do not document a kendex class selector or an executable model field. The Codex custom-agent model field is static. A Copilot agent model outranks the launch model. Cursor carries no model field. Writing a versioned id at render time does not establish later runtime resolution.

The chosen boundary is:

- Managed root launches with launcher-built model flags resolve classes immediately before the existing launcher passes a confirmed native model selector or preserves native default with no model flag. Custom `--cmd` model rewriting is cut to [KEN-2543](https://linear.app/vanillagreen/issue/KEN-2543).
- Ship the Claude mod within the existing orch skill at `scripts/claude-model-classes/`. Managed launchers use the installed skill's path with `--plugin-dir`. A direct session loads the same mod with documented `--plugin-dir` or `CLAUDE_CODE_PLUGIN_DIRS`. The current kendex plugin declaration only toggles an externally installed plugin. Do not turn it into a new installer or introduce an SDK runner.
- For a kendex-declared Claude child, the mod sends the native agent identity and working directory to `tier-model --agent`. Core reads the same source and manifest overrides as rendering. It preserves the requested class even when the valid native field contains an alias. `agent.spawn` uses the core-selected selector or the native parent/default selection. The latter overrides an unconfirmed rendered alias and needs no new exact-id probe. Missing model access or capacity never returns `{ deny }`. No runtime file rewrite is needed.
- For a root class request, launchers pass `KENDEX_MODEL_REQUEST` as intent beside the selected native flag or native-default action. `turn.step` calls the same resolver. It streams `next({ ...e, model })` for a confirmed explicit selector. For `HarnessDefault`, it keeps or restores the harness session/default selection instead of reapplying the unconfirmed class alias. A direct session can supply that intent too. Requests with `e.agentId` do not inherit the root class again. Untagged roots and undeclared children keep native behavior.
- The native path requires Claude Code v2.1.287 or later, a loaded mod, kendex on the session's PATH and policy that permits its process calls. Disabled hooks, safe/bare mode, blocked sideloading and competing model-changing mods are explicit limits. Managed class launches refuse a known unsupported setup. Unmodded direct aliases still have native rejection behavior, not kendex fallback.
- Callback integration failures must stop the covered request. Attach `.catch` handlers because Claude Code otherwise skips a failed hook. Child integration failures return `{ deny }`. Root integration failures answer the streaming event without calling the model. Missing or failed model evidence is a structured native-default result, not one of these failures. The plan pins both behaviors to the native types and tests.
- Copilot class renders continue to omit the model field under D008. They inherit the managed session's resolved model.
- Codex class renders also inherit the managed session. They must report this limitation, not claim an independent child class.
- Direct native custom-agent launches without an independent runtime selector support `inherit`, verified native aliases and explicit ids only. An independent class request with no supported runtime path is refused. Claude has that path when the mod is loaded; Codex and Copilot retain the managed-session limit.
- Gemini, OpenCode, Antigravity and Cursor keep their native capability boundaries. No unverified class keyword or model hook is installed for them.

This does not claim independent runtime class resolution in every native custom-agent file. The owner accepts Codex/Copilot managed-session inheritance and Claude's version, mod-loading and policy conditions. Unsupported native paths remain unsupported. They do not justify another product decision before implementation. A new wrapper harness, an internal-file rewrite or prompt-only model steering is not the fallback.

## Evidence limits

OpenAI's current model page verifies `gpt-6-luna`. It says: “Our most efficient model for focused, high-volume tasks.” Its current full catalog names GPT-5.6 Terra and GPT-5.6 Luna. The Terra page says: “It roughly corresponds to the mini model tier used in earlier GPT-5 families.”

The direct official URLs for GPT-6.1 Luna and GPT-6.1 Terra return HTTP 404. The retrieved current catalog does not list them. Their requested versions and the Luna-light/Terra-fast ordering are owner policy, not a verified OpenAI capability or price ordering. The table retains that family policy. The resolver never manufactures an id absent from the consumer's model inventory.

Claude Code's model documentation says aliases “point to the recommended version for your provider and update over time.” It also shows different alias versions by provider. The promise is the harness's moving recommendation, not the newest worldwide release on every gateway.

The [mods overview](https://code.claude.com/docs/en/plugins/mods/overview) sets the minimum version to v2.1.287. It documents hooks in terminal, print and SDK sessions that load the plugin. The reviewed mods API exposes session model and usage facts, but no general selectable-model list. Reuse `Query.supportedModels()` only from an existing SDK host. A model reported at startup is not a new entitlement or capacity measurement. Missing evidence keeps the harness's own default/session path with one warning. It does not authorize a different family alias or an invented capacity.

The native declarations vary by Claude version. After build authorization, read the declarations generated by a disposable plugin load. Native tests must confirm child identity, working-directory binding, callback precedence and the streaming refusal shape. The documentation confirms the callback choice. It does not supply live proof of those integration details.

## Rationale

- One owner removes the separate Rust tier map, shell alias pins and Pi agent normalization map.
- Native aliases let the harness apply its account and provider rules.
- Availability filtering avoids starting a consumer on a model selected only because kendex ships its name. Native default fallback lets the harness select its own model when kendex cannot confirm the requested class.
- Explicit refusal preserves the difference between an unsupported loader and an available model.
- Claude's native callbacks allow runtime fallback for direct declared children without replacing the harness. Shipping the mod in orch reuses the existing package delivery path.
- D008 remains active. No Copilot model pin replaces the operator's launch selection.
- D015 remains active. Model selection does not change the shared context handoff rule or Copilot's usage-event reader.

## Alternatives considered

| Alternative | Reason for rejection |
| --- | --- |
| Keep vendor names as the public class names | `opus` would continue to mean both a class and one vendor's family. Neutral class names make that distinction explicit. |
| Copy mappings into orch and Pi | Callers could disagree on membership, availability and fallback. |
| Rank all providers by price or benchmark | Neither a signed-in account nor a model catalog supplies a portable capability ranking. The task does not authorize one. |
| Query each provider directly | Adds account probes and assumes credentials belong to a provider API rather than a harness subscription. |
| Treat installed directories or usage windows as entitlement | Neither names the models the account can currently select. |
| Refuse unknown access or capacity | Blocks a first usable launch because metadata is missing. The harness's own default/session selection keeps launch usable without inventing a model grant or capacity. |
| Rewrite generated agent files on every hook | Races concurrent sessions, changes recorded renders and depends on undocumented reload behavior. |
| Keep all Claude fallback in managed launches | `agent.spawn` and `turn.step` provide documented native model callbacks. A loaded mod can use the core owner directly. |
| Add a service, persistent model cache or new SDK runner | The existing resolver, CLI, account chooser and extension dispatcher own the needed lifetimes. |

## Consequences

- A new family or a family reordering changes one row. A new available version changes no kendex code when a native alias or harness model list exposes it.
- A harness without a moving alias or usable list still needs one preferred-id table edit. The design does not promise automatic updates there.
- A first managed launch with unknown model access or capacity uses the native default/session path with one warning. It can use a weaker or more costly model than requested. This occurs whenever the required metadata is absent or unread; the warning names that limit.
- Fleet providers can append model evidence and native-default capability to their existing account rows. They need no new account-probe verb. An omitted default id does not mean the harness lacks a usable default path.
- Direct Claude class fallback requires the shipped orch mod to be loaded on a supported version. Disabled or policy-blocked mods cannot enforce it. Covered callbacks use native default/session selection for unknown model facts and still refuse actual integration failures.
- The rejected size/risk helper and its CLI inputs are absent from P3. `crates/cli/src/commands/tier_model.rs::run` retains explicit model requests. The existing Top model reason belongs to the item brief, not the resolver protocol.
- P5 must preserve the existing item-specific Top model reason in the brief and consume it with the explicit request. A generic risk label is not a reason. General CLI class requests remain readable. Their compatibility does not authorize an unjustified item choice.
- The fleet overseer owns the later standard-class trial on vg. The trial measures the chosen default. It does not postpone standard or authorize a new default without an owner ruling.

**Revisit When**: A remaining native loader gains a documented runtime class/model callback; Claude changes mod callbacks or supplies a selectable-model list; harness model lists gain stronger entitlement evidence; a newer Haiku becomes owner-approved; or the owner changes the standard default after trial evidence.

**Verification**: The implementation and must-fail controls are specified in [the plan](../plans/model-class-resolution.md#proof). They distinguish native-default success, confirmed no-model refusal, actual account walls and callback integration errors. The original design stage ran no tests or builds. P3 receipts belong to the integration return artifact. P4 and P5 proof remains pending. The owner authorizes implementation of the amended design under the existing brief.
