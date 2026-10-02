# Model class resolution

The approved policy requires standard for overseers and lanes. Top requires the existing item-specific Top model reason. P3 implements core and Pi model resolution with native default/session fallback for unknown access or capacity.

## Integration status

| Piece | Scope | Status |
| --- | --- | --- |
| P3 | Core resolver, CLI, overrides, native renders and both Pi child paths | This integration round; completion receipts belong to its return artifact. |
| P4 | Claude runtime mod and tracked orch render | Pending. Native callback declarations and fixtures do not prove a loaded session. |
| P5 | Account evidence, lane picks, launch adapters and context handling | Pending. Current consumers retain their existing behavior until integration. |
| KEN-2496 | Overseer ladder defaults | Separately owned. Preserve current values in P3. |

Later-stage sections describe requirements. They do not claim that P4 or P5 has shipped.

## Framing

- **Goal**: Replace version pins with one class decision for rendering, overseers and lanes, within native harness limits.
- **Perspective and constraints**: Owner-authorized policy amendment under code-quality, docs-writing, decider and document byte/growth limits. Change only the allowed design artifacts.
- **Decision**: [D021](../decisions/D021-runtime-model-classes.md) authorizes implementation without another owner read. [Evidence](model-class-resolution-evidence.md#design-history) records the contract and history.
- **Assumptions**: A harness model list describes selectable models under current authentication and policy. It cannot prove that a later request will succeed. A first successful turn remains the runtime access check.

## Owner authorization and contract limits

[D021](../decisions/D021-runtime-model-classes.md) binds model fallback: unknown access or capacity uses the native default/session model with one warning. Model resolution refuses only when no usable harness model exists.

The accepted limits and the amended behavior are:

| Limit | Chosen behavior | Accepted boundary |
| --- | --- | --- |
| Codex/Copilot static custom-agent fields | Inherit the resolved managed session. Refuse unsupported independent child classes. | No independent child-class promise. |
| Claude mod loading | P4 must ship `agent.spawn` and root-only `turn.step`; both must call core. Require v2.1.287 and explicit direct-session loading. | Missing/disabled mod routes remain unsupported. Unmodded aliases have native rejection only. |
| Claude policy and callback order | Respect safe/bare mode, disabled hooks, sideload/process policy and competing mods. | Native receipts must prove identity, working directory, precedence and refusal. No policy bypass or universal priority. |
| Installation/sign-in is not model access | Reuse existing account facts and native lists. No new account probe. | Unsupported, failed and complete-empty evidence stay distinct. None alone closes native default. |
| Claude prospective capacity | Keep `lane_adapter_claude_window` and known account-wall judgments. Different explicit candidates need model-bound evidence. | Unknown capacity stays unknown and uses native default. No borrowed window. Account/integration errors stay separate. |
| Claude moving aliases | Pass the provider recommendation unchanged. | Not the newest release on every gateway. |
| A provider has only a top-family model | Fallback can select top with one warning. | Availability fallback can differ from the requested standard class. This is not an item promotion. |
| Exact Haiku pins | Substitute Haiku 4.5 or earlier through core with one warning. Confirmed newer Haiku pins stay exact with one compatibility warning. | Bare `haiku` remains fast. Fast has no Claude member. Unknown access/capacity uses native default. |

[D021 § Runtime boundary](../decisions/D021-runtime-model-classes.md#runtime-boundary) owns unsupported-route limits. Require integration proof.

## Approach

Extend `crates/core/src/harness/models.rs` and `crates/cli/src/commands/tier_model.rs`. Do not introduce another model command owner, a service or a persistent model cache.

`resolve_model` owns parsing, aliases, overrides, family matching, availability filtering, fallback and diagnostics. It also owns the decision to use the native default when access or capacity is unknown. Renderers and runtime callers only encode its tagged result in the native format. Orch supplies account and usage facts. The Claude mod and Pi dispatcher supply native runtime facts. No caller decides what a class means.

### Class table

`crates/core/src/harness/models.rs::TIERS` owns class membership, legacy aliases and preferred selectors. [D021](../decisions/D021-runtime-model-classes.md#decision) records the approved family policy. The table does not prove account access or the existence of an unlisted preferred version.

Canonical names replace the old public class names. The old names remain accepted input aliases without a separate compatibility table. A provider-qualified `anthropic/opus` denotes that provider's native family selector, not a neutral standard request.

Do not enable a Claude fast class member from a model list alone. A class member requires owner approval. Confirmed exact Haiku newer than 4.5 remains usable as an exact request under D021. Core substitutes versions at or below 4.5.

Other providers do not receive guessed Fable, Opus or GPT equivalents. Their usable default or available chat model supplies the unclassified terminal fallback. Existing Gemini and Antigravity native selectors remain native selectors, not evidence that an account has a class member.

### Inputs and result

Use tagged Rust values, with exhaustive matches:

- `ModelRequest`: `Inherit`, `Class`, `NativeFamily` or `Exact`.
- `ResolutionContext`: `Render` or `Runtime`. Runtime carries the harness, target account/host, admitted provider identities, model-list evidence, a separate harness default/session path, model-bound capacity evidence and explicit rejected candidates.
- `ModelListEvidence`: `Complete`, `Unsupported` or `Failed`. `Complete` can contain an empty list. `Failed` retains source and cause. An absent model-list interface is `Unsupported`, not a complete empty inventory.
- `HarnessModelPath`: `ObservedSessionOrDefault`, `NativeDefault` or `NoUsableModel`. The observed case carries a native selector and an optional concrete id. `NativeDefault` preserves a supported harness-owned default/inherit action without requiring an observable id. `NoUsableModel` needs affirmative evidence that neither an explicit model nor the native default/session path is usable. An unread or absent id never creates that state.
- `ModelCapacityEvidence`: `Known` or `Unknown`, bound to the model/account/host it measures. Unknown retains a missing or failed source cause. Do not reuse a previous model's window for a different model.
- `ModelResolution`: `Inherit`, `NativeAlias`, `Selected`, `HarnessDefault`, `DeferredClass`, `Unmanaged` or `Refused`. `Unmanaged` is valid only for the native agent-identity lookup; it is not fallback or a launch selection.
- A selected result carries the requested class, effective class when known, provider, native launch selector, optional known concrete id, evidence source and structured diagnostic causes.
- `HarnessDefault` is a launchable runtime result, not an empty inventory or `Inherit` request. It carries the original request, requested class when present, the observed session selector or native-default action, optional observed id/provider and diagnostic causes. Capacity is `Unknown` unless independently supplied facts measure that same fallback model. Retain the requested candidate's diagnostics, not its capacity figure for a different fallback model. The result does not claim a confirmed class member. No id, provider, effective class or capacity number is invented.
- Render results never claim an account entitlement check. Deferred results never count as a launch selection.

The runtime inventory and default path contain no credentials. Bind them to the account and host they describe. A model available on the control machine cannot certify a hosted lane's copy. Preserve `NativeDefault` whenever the target harness can choose its own model and that path is not confirmed unusable. Do not add a probe to fill an optional id.

### Override

Add `Manifest.model_classes`, serialized as `model-classes`. Use the existing manifest loader and validator.

A consumer sets one dotted-key line before any TOML table:

```toml
model-classes.fast = "my-provider/my-model"
```

- The class key is one canonical class. Unknown keys, empty selectors, class-to-class redirects and inherit overrides refuse.
- The value is a provider-qualified exact id or documented native family alias. No patterns, priority language or embedded shell commands.
- Replace that class's members for this scope. Do not append a second candidate chain.
- Read personal and project manifests through their existing paths. The project replaces a personal class value per key. The source catalog cannot override a consumer's class policy.
- Apply the model and provider availability checks after the override. A configured value is not access evidence.
- Refuse an override selecting Haiku at or below 4.5. A confirmed missing override member follows the normal class fallback. Unknown override access or capacity uses `HarnessDefault`. Both produce one warning and never certify the configured value as accessible.
- Include the effective override inputs in `crates/core/src/hash.rs::installation_hash`. The engine already owns declaration hashing.
- Keep the current manifest schema. This is an additive optional section, not a migration. The new parser reads existing files unchanged. An older binary will refuse a manifest that uses the new section; the rollout documentation must say so.

### Family freshness

The family matcher belongs beside `TIERS`, not in shell, renderer or TypeScript code.

- Prefer the native moving selector when the target harness exposes it and availability evidence admits it.
- Otherwise match only available chat models with the row's anchored family grammar. Parse numeric release components numerically, not by lexicographic id order.
- For a GPT family, match `gpt-<release>-<family>` and its dated snapshot form. For Claude list ids, match `claude-<family>-<release>` with the provider's separators and optional snapshot date.
- Compare release components first. For the same release, prefer the undated alias over snapshots. If only snapshots remain, prefer the newest valid date. Use the full provider/id as the final stable tie-break.
- Treat unrecognized suffixes as unclassified candidates. Do not infer that preview, cyber, pro or another suffix is a newer member of the requested family.
- A preferred table id is only a candidate. It is never added to an availability list. In a no-list context it can match an observed usable current/default id, but cannot create access evidence.
- The owner-requested Luna and Terra versions remain policy entries. An account list that contains only an older member can select that older available release. Emit `family-version-unavailable` in the same warning line.
- A future family grammar change or family reordering changes this one owner. A harness list or native alias can expose a new version without a kendex release.

### Availability and fallback

`HarnessAdapter::detect` and `engine::ops::detected_harnesses` supply installation targets, not authentication or model grants. `lanes::emit_lane`, `host_account_records` and `model_buckets` own account/usage facts, not model access. No family label or monthly pool proves entitlement.

Resolve each account in this order. [D021 § Fallback and compatibility](../decisions/D021-runtime-model-classes.md#fallback-and-compatibility) owns the unknown-evidence and native-default rules.

1. Bind evidence to the detected harness or admitted host-account row. Pi uses its running authenticated registry. Intersect explicit candidates with that context's available chat models. Exclude policy-denied models and Haiku versions at or below 4.5. Carry native default separately; it cannot bypass confirmed denial. Add no accountInfo/login/renewal/provider probe.
2. Return `no-model` only on affirmative evidence that no explicit or native path is usable. Unknown/unread access returns `HarnessDefault` with `model-availability-unknown` and source causes. Use an observed usable session selector or the native default action. Discovery failure never advances to another table candidate or requires an id probe.
3. Walk requested class, lower classes in order, then higher classes nearest first. Visit each once. Within a row prefer the current provider, then harness/default provider order, then stable provider/id order. Apply § Family freshness only to admitted candidates.
4. Pass confirmed selectors to `lane_selection`, `with_lane_binding` and `wall_verdict`. Keep scoring, claims and projection. A confirmed wall rejects that candidate and permits fallback. Unknown model-specific capacity/admission instead ends retries with `HarnessDefault`, `model-capacity-unknown` and source causes. Keep actual account walls and account-read failures distinct.
5. After named families, choose available default, current, sole chat model, then the first unclassified chat model in stable provider/id order. Warn `unclassified-provider`. If no explicit candidate remains but native default is usable, use `HarnessDefault`. This is availability fallback, not capability ranking.
6. `Complete([])` closes only explicit list candidates, not native default. `Failed` remains failed with source diagnostics, never empty success. Keep fallback capacity unknown unless independent facts measure that same model. Invent no id, class or capacity.

The finite inventory bounds retries. `HarnessDefault` ends retries on that account/host. Missing capacity cannot produce `lane-provider-unmeasured` for native default; known exhausted accounts stay blocked. A singleton custom Pi model can serve each class with one unclassified warning.

### Inherit, exact ids and warning ownership

[D021 § Fallback and compatibility](../decisions/D021-runtime-model-classes.md#fallback-and-compatibility) owns pin, inherit and Haiku rules. Preserve `old-id`, `model-unavailable` and `excluded-haiku`. Keep catalog agents on inherit. Source frontmatter and manifest model overrides share parsing/precedence. Positional rank remains readable with a selector-only warning; runtime uses evidence-bearing input.

Core carries diagnostics without printing. `desired_agent` owns render warnings; `lanes` owns pick warnings; the top-level launcher relays the pick warning once. Pi dispatch and direct Claude callbacks own their child/session warnings. JSON carries causes, not printed prose. Each process emits at most one combined warning and keeps later causes structured.

Managed Claude launch passes receipt and latch to the mod. Literal `$.env.get`/`$.env.set` for `KENDEX_MODEL_WARNING_EMITTED` preserve that latch across reload and `/clear`. Initialize it per launch. Add no machine store or per-subprocess latch.

The warning starts `model-resolution: requested=<request> selected=<selector-or-native-default> causes=<keys> source=<sources>`. It retains failed-source causes and the original pin when no class exists. Refusals start `model-resolution: refused=<cause> requested=<request> harness=<harness>`. Unknown access/capacity are warning keys, not refusals. Keep no-model, unavailable pins, account walls and integration errors distinct. Include bound account/host where relevant. Print no credentials or recovery commands.

## Harness interfaces

This table checks interfaces in the required order: SDK, extension/plugin API, events/RPC, hooks, settings.

| Harness | Interface review and selected path | Runtime and access boundary |
| --- | --- | --- |
| Claude Code | Existing SDK hosts can use `Query.supportedModels()`. Select native mod `agent.spawn` and `turn.step` for runtime enforcement. Native settings/frontmatter/`--model` keep family aliases. | Require v2.1.287 and permitted mod/process calls. No general mod selectable-model list. No new SDK host or account probe. Callback/default encoding is specified below. |
| Codex | SDK starts threads but documents no standalone list. No reviewed plugin model callback. Select stdio app-server `model/list` under the target account, with initialization and complete pagination. Tool hooks do not execute TOML model fields. | Start no model turn; close the process. Selected ids reach root launch. `HarnessDefault` omits the model flag or preserves a usable session selector. Custom agents omit class fields and inherit managed sessions. Independent classes remain unsupported. |
| Copilot | Select SDK `CopilotClient.listModels()` over CLI `models.list`. Its connection owns capabilities, policy and cache. The existing context extension owns events. | Respect denied models. No help/picker/status scraping. Root `--model` carries selection; native default omits it. D008 omits class model/effort fields for managed-session inheritance. |
| Pi | Select existing extension `ctx.modelRegistry` and parent model. SDK `ModelRuntime.create()`/`getAvailable()` exposes usable authentication. RPC remains an alternative, not another discovery path. | Keep frontmatter class tokens. Call core before both child launch forms. Selected provider/id reaches `--model`; default keeps the usable parent or native child default. Bind evidence to child working directory/runtime. |

For other renderers, preserve the existing native format and capability rules. A supported documented native alias can be encoded as an alias. Otherwise use managed-session inheritance with a limitation result, or refuse an independent runtime class. Cursor never gets a fabricated model field. Update `model_shape` and render validation to recognize only selectors the receiving loader actually accepts.

### Claude native mod

Choose both documented callbacks. `agent.spawn` owns independent child selection before startup. `turn.step` owns explicit root class selection before a request. It also observes the actual response model when supplied. It does not reapply the root class to a child whose `e.agentId` is set. Using `turn.step` alone would postpone child refusal until after startup. Using `agent.spawn` alone would leave root requests without a native runtime callback.

**Packaging and loading**:

- Add `skills/orch/scripts/claude-model-classes/.claude-plugin/plugin.json`, `hooks/hooks.json` and `hooks/register.js`. The hooks document uses `modules: ["./register.js"]`. Claude loads JavaScript directly. No Node.js dependency, bundler, new service or SDK runner is needed.
- This mod ships as files within the existing orch skill. The matching `.agents/skills/orch/scripts/claude-model-classes/` render ships in the same commit. Native plugin directories are not a new kendex item kind.
- `source/plugin_registry.rs` reads marketplace content. `engine/desired_kinds.rs::desired_plugins` only toggles `enabledPlugins`; it installs no plugin payload. Keep both boundaries. Use the documented directory loader instead of inventing an installer or altering the native installed-plugin registry.
- `ol_launch_flags` and `open-terminal` pass `--plugin-dir` with the absolute directory below their installed `SCRIPT_DIR`. Hosted launchers use the host's installed skill path, never a control-machine path. Direct users load that same directory through `--plugin-dir` or `CLAUDE_CODE_PLUGIN_DIRS`. Do not overwrite a consumer's configured plugin directories or enable disabled hooks.
- The full native class path requires v2.1.287 or later and the mod to be loaded. `--safe-mode`, `--bare`, `disableAllHooks`, managed sideload restrictions and policy-denied `process.run` prevent this path. Managed routes reject a known unsupported setup with `model-runtime-unsupported`. Unmodded direct launches remain native-only. This plan adds no priority shim for competing model-changing mods.

**Request and decision**:

- Add `tier-model claude --agent AGENT --runtime-context-json JSON --json` as an input form on the existing command. Core looks up the enabled kendex declaration at the effective working directory. Read the installed source revision from the local cache through the sealed source reader. Do not fetch, refresh or update a catalog during a callback. An absent cached source refuses. Add `engine/desired_agent.rs::agent_model_request`, exported through `engine/mod.rs`, for the read-only lookup. Reuse `effective_agent` and `render/agent/mod.rs::merge_overrides`. Add `EffectiveAgent::model_request` as the shared source/override precedence reader used by render and runtime. Preserve `harness::rendered_name` and plugin-qualified installed names. Core returns a tagged `Unmanaged` answer for an identity outside its declarations. A failed source/manifest read, ambiguous identity or edited managed installation refuses instead of becoming unmanaged.
- The mod obtains the agent identity from the native `agent.spawn` input and the session working directory through `$.session.cwd()`. Use the version-matched declarations for field names; do not guess names from settings-hook payloads. A supplied child working directory must bind the request to that directory. If the native event cannot identify the declared child or its different working directory, deny that covered spawn and return an integration blocker. Do not select by prompt text or inspect internal native files.
- For a declared class, core retrieves the original intent from that reader. The native frontmatter retains a valid alias or `inherit`, not `top` or `fast`. A fast render that encodes sonnet therefore still requests fast at child startup. No second per-agent class map or runtime render rewrite is needed. The mod only transports the intent lookup and evidence.
- Call `tier-model` through documented `$.process.run` with an argument array and `--runtime-context-json`. This avoids assuming an undocumented stdin option. The JSON contains no credentials. Use the native process deadline from the version-matched types. Observe `next.signal` and never forward an abandoned result. Check exit status, JSON tag and protocol before using the native selector. Do not access Node.js process APIs from the hooks module.
- `agent.spawn` calls `next({ ...e, model: selected.nativeSelector })` for confirmed selection. A model-only return short-circuits startup. `HarnessDefault` forwards a changed event that overrides an unconfirmed declaration alias with native parent/default selection, including native inheritance without an observable id. `Inherit`/`Unmanaged` call `next(e)` unchanged. Confirmed no-model and integration failures return `{ deny }`. Pin these actions with supported-build types and require one downstream startup call.
- A managed root launcher with launcher-built model flags passes `KENDEX_MODEL_REQUEST` as the original core request beside a selected native `--model` or a native-default launch with that flag omitted. It also supplies the evidence-bearing launch receipt, default action and warning state through `KENDEX_MODEL_CONTEXT`. A direct root class request can use the same intent variable. Missing model evidence then returns `HarnessDefault`, not a refusal. Read those names with literal `$.env.get` calls. The environment carries facts and intent, not a class table or credentials.
- For a root event with that intent, the async-generator `turn.step` handler obtains native session facts and calls core. A confirmed selection uses `yield* next({ ...e, model: selected.nativeSelector })`. `HarnessDefault` retains the actual session/default selector. If no id is observable, forward the native default request without injecting the class alias or a table id. No intent means `yield* next(e)`. Child events keep their spawn selection. A root event that names a changed model outside the prior selected selector withdraws the root class intent; treat that as an explicit native model change instead of restoring the class. A receipt with no observable selector cannot prove such a change and must keep the native default path. Core judges selector equivalence. Do not duplicate alias matching in JavaScript.

**Failure and evidence**:

- Attach `.catch` for CLI failure, timeout and invalid protocol/results. Spawn denies; root ends the native step with no tools or `next`. Evidence-read failures instead reach core as tagged evidence and preserve default. Pin both paths with native types. After forwarding, inspect `next.called`; stop on error without another model call. Refusal cannot undo a sent request.
- Error handlers use known diagnostics/event fields within the native budget. They run no process or evidence read. Skipped, disabled or unloaded mods remain unsupported, not passing class launches.
- The native session/model/usage facts and effective parent do not enumerate entitlement. Reuse a same-account SDK list only from an existing host. Preserve the observed usable parent/session or native default without inventing an id. Keep empty-list and failed-source states distinct, with diagnostics in the shared warning.
- Bind capacity metadata to its actual model. A changed root candidate needs a matching account/host admission receipt from the existing launch judges. Missing prospective capacity/admission uses `HarnessDefault`; known walls still block. Never borrow a previous window or add capacity numbers to the class table.
- Generate native types only in a disposable worktree-local plugin copy. Missing identity, child-directory binding or refusal types blocks integration. Missing default ids or model facts keeps default. § Proof owns the required native receipts.

### Runtime evidence transport

Extend the existing `tier-model` command, not the command roster with a competing resolver:

```text
kendex tier-model HARNESS --model standard --runtime-context-stdin --json
kendex tier-model HARNESS --model top --runtime-context-stdin --json
```

Keep rank, `--model` and `--agent` mutually exclusive. Remove the unreleased `--item-tier` and `--risk` inputs. Orch sends the explicit class selected under § Default selection. Only Claude callbacks use `--agent` and its shared intent reader. `--runtime-context-json JSON` and stdin are mutually exclusive transports into the same decoder.

Runtime context carries tagged list/default evidence, candidates, model-bound capacity and account identity. Use `protocol = "model-resolution-v1"` in request and response. Reject malformed input, unknown tags, unsupported protocol and account/host mismatches. Only `Selected`, witnessed `NativeAlias` and `HarnessDefault` launch classes. `Inherit`/`Unmanaged` pass through Claude agent lookup; `DeferredClass` cannot launch. Failed model evidence uses `HarnessDefault`, not refusal.

The model-list collectors normalize the documented harness payloads into that input. They perform no ranking. Rust owns family interpretation and fallback. Missing interfaces become `Unsupported`. Read, parse, subprocess and incomplete-pagination failures become `Failed` with the actual source and cause. Never pass partial discovery as complete or discard a failure as an empty list. Collectors preserve the independent native default/session path on all these outcomes. Short-lived native list subprocesses use `crates/core/src/process/mod.rs` where core launches them. A collector in a harness-owned extension uses that extension's existing process owner. Do not add persistent connections solely for selection.

For hosted lanes, append optional model evidence fields to the existing `accounts` row and normalize them in `host_account_rows`. Define `models-json`, `model-default` and `models-status` in `skills/orch/schemas/lane-host.md`. `models-status` distinguishes complete, unsupported and failed and carries source diagnostics through normalization. `model-default` carries the tagged harness path and optional observed selector/id, not a required exact id. Values contain no tab or newline. Require explicit inventory and observed default facts to come from the host's documented harness interface. Preserve the documented host-local native default action when no id is returned. No new `accounts` invocation or account-probe verb is introduced. Old providers lacking those fields remain readable. They cannot certify a class member from usage alone, but missing fields do not disable their native default launch path.

### Context window and compaction

`lane_adapter_claude_model_id` currently pins sonnet and haiku. That pin exists because `lane_adapter_claude_window` needs an id for capacity checks. Remove the launch alias-to-id translation, not the capacity check.

- The resolution result separates the native launch selector from the known concrete id. Launch with the alias. Measure capacity against the actual model identified by native metadata or the existing session reader.
- Keep `lane_adapter_claude_window` as the one Claude capacity judge. The core class table contains no copied context-window numbers.
- Preserve disabled auto-compaction launch flags and `lane_context_handoff_due`. A newer model with no trusted capacity remains unmeasured. It is never assigned a guessed window from the class name. The handoff owner retains an explicit unknown measurement until native metadata arrives; it does not claim a measured threshold or turn that absence into a launch refusal.
- A prelaunch capacity check uses known model-bound metadata when available. When a moving alias has no such metadata, it returns structured `model-capacity-unknown` to core. Core selects `HarnessDefault`, and `lib/lane-launch.sh` launches that native path with the single warning. It does not restore a version pin or a guessed number to make the check pass.
- A current native session's model-bound reading can inform a later managed launch. Do not require an actual-id reading to preserve a native default. Do not start a paid turn only to obtain that reading.
- Settings-hook `SessionStart.model` is optional and does not prove future `/model` changes. It cannot be the only capacity source. The mod can supply `session.model`, response `usage.model` and `session.usage().context.window` as native observations. Bind each capacity reading to the model it actually measures, as specified in the native mod section.
- Copilot keeps D015's `session.usage_info`, token limit and compaction threshold. Pi keeps its selected model metadata. No class label replaces those figures.

A first Claude light launch with only alias intent and unknown capacity uses the harness's own default model with one warning. The capacity stays unknown. A later native observation can enable model-bound context checks. The existing context owner still acts on confirmed limits. The amendment permits launch without that measurement; it does not claim that a missing measurement passed.

## Default selection

[D021](../decisions/D021-runtime-model-classes.md#decision) requires standard for overseers, successors and lanes. GPT-6.1 Sol takes Astra's former default tasks. All workflow tiers use that default. `item-tier` still selects the workflow; its estimate, size and escape floor never select a model. Generic complex/high-risk categories never select top.

The existing `workflows/oversee.md` Lane directive owns item selection. The overseer reads the item's existing labels and body. It requests top only when the item names why it needs top. A label must carry that reason, not merely a risk category or `top` name. The overseer writes `**Top model reason**: <item-specific reason>` into the brief it already mints, including a copied label reason. The launching orch lane reads that field. Keep the reason on recovery and successor briefs for that same item. Without it, an item cannot select top through a preference, alias or pin.

Use the existing `lanes --model` and `tier-model --model` inputs. Default item requests send `standard`; justified top requests send `top`. The reason belongs to the overseer/brief contract, not to the general resolver's availability protocol. Add no CLI reason flag, reason parser, tracker field or label taxonomy. General explicit classes, aliases, exact pins, inherit and `model-classes` overrides remain readable. Their compatibility does not grant an unjustified top item request. Availability fallback can still select top; it is not a top request. Preserve explicit consumer route order and numeric-entry migration.

**Core item policy**: The rejected design mapped workflow size and generic risk to model classes. That helper and its CLI inputs are absent from P3. `crates/cli/src/commands/tier_model.rs::run` uses the existing explicit request parser. Standard and justified top requests use that path. The ordered steps below retain the original proof requirements.

**Separate ladder boundary**: The owner assigns the actual default-ladder edit to another item. KEN-2496 owns its `OL_DEFAULT_PREFERENCE`/default `ORCH_OVERSEER_PREFERENCE` changes. This branch must not edit that constant, its default-list examples or its default-value assertions. It changes only the existing consumer's resolution, evidence and launch-result transport. Unset lane preference requests standard here. Coordinate the other item's deployment before claiming the fleet default is active. Preserve the separately owned KEN-2496 scope.

## Ordered implementation plan

The owner authorizes the standard-default and native-default amendments. The orchestrator delegates the core correction in this branch, then runtime integration. All proof below belongs to implementation. The separate item owns the actual ladder-default edit.

1. **Core item policy**: Keep the rejected size/risk mapping absent as specified in § Default selection. Preserve the exact-Haiku policy in D021. Proof: rejected size/risk inputs cannot select a class; explicit standard/top still use the existing parser. Core and CLI controls below hold this correction.
2. **Complete the core owner**: Extend `models.rs::{TIERS,resolve_model,ModelResolution}` and tests for the tagged shapes, family matcher and fallback above. Keep native-format concerns separate. Proof: the core rows in § Proof cover request kinds, family/class holes, termination, evidence/default states and refusals. They reject provider leakage, repeated classes and fabricated model/capacity.
3. **Read consumer overrides once**: Change `crates/core/src/manifest/mod.rs::Manifest`, `manifest/validate.rs::TOP_LEVEL`, validation and tests. Read through `manifest/file.rs::load_current` and `parse_text`. Thread the effective class overrides through `engine/desired_agent.rs::desired_agent`, `EffectiveAgent` and installation hashing. Proof: parse/save round trips, personal/project precedence, unknown and disallowed selectors, and hash invalidation. A mutant that ignores the project override must turn its test red.
4. **Complete the existing CLI bridge**: Use `TierModelArgs`/`run`, CLI dispatch and the shared `engine::agent_model_request`/`EffectiveAgent::model_request` reader. Keep model/context/JSON and Claude agent forms, not size/risk inputs. Preserve positional rank with its selector-only warning. Proof: fixture-home tests cover protocol/tags, confirmed selector, default without id, refusal status, clean stdout, one warning, malformed input, source/override precedence and managed/unmanaged identity. Managed-source failures refuse; model-evidence failures default. Use the existing `crates/cli/tests/tier_model.rs` registration.
5. **Complete native evidence collection**: Use core `models/{codex,evidence}.rs`, the hardened process owner, Copilot's SDK helper and Pi's existing runtime. Claude lists come only from an existing SDK host. Extend existing host-account rows, not account detection. Collectors preserve policy, tagged failures and native default; their clients start no conversation and close on every exit. Proof: scripted peers cover init/pagination, denied policy, process/discovery failure and account/host binding. Old rows and empty lists keep defaults. Live receipts establish actual returned models.
6. **Add native Claude dispatch and valid renders**: Ship the mod/render paths in Files and implement § Claude native mod with disposable supported-build types. Update native renderers and validation. Claude carries aliases with core intent; Pi keeps classes; Codex/Copilot inherit managed sessions. Proof: § Proof covers callback selection, precedence, non-interference, warning lifetime, defaults and refusals. Loader readback rejects unsupported class fields.
7. **Resolve before lane measurement**: Change `skills/orch/scripts/lanes::{cmd_pick,cmd_pick_lane,collect_lanes,host_account_rows,pick_host_rows}`. Pass account rows and tagged inventory/default facts to `tier-model`; feed confirmed selectors to `lib/lane-model.sh`. Picks retain `HarnessDefault`, optional selector/id, requested class and diagnostics beside `config_dir`. Apply § Availability and fallback without changing account scoring. Proof: fleet/named-lane fixtures cover missing/failed lists, unknown capacity, known walls and absent measurement. Measuring original fast instead of resolved sonnet must fail its control.
8. **Integrate existing overseer and lane consumers**: Change `lib/overseer-launch.sh::{ol_preference_entries,ol_entry_model,ol_pick_record,ol_pick_lane,ol_launch_flags}` and `open-terminal::preference_select` plus flag assembly. Apply § Default selection through the existing brief/model inputs. Do not edit `OL_DEFAULT_PREFERENCE` or duplicate the other item's default-list work. Encode the picked tag, not an original class or table pin. Claude receives host-local mod path and intent/evidence/warning receipt. Readiness uses documented version/settings. Proof: default item argv requests standard across workflow tiers; justified top remains explicit. Selected/default launch, host-local loading and failure cases retain their tests.
9. **Remove the Claude pin used for capacity**: Change `lib/adapters/claude.sh::lane_adapter_claude_model_id`, its caller and prelaunch window check in `lib/lane-launch.sh`, and `lib/lane-context.sh::lane_context_handoff_due`. Apply § Context window and compaction. Proof: adapter/launch tests cover aliases, overrides, newer actual ids, absent default ids and unknown-capacity launch. Controls reject stale pins, borrowed/guessed capacity and restored gating.
10. **Resolve Pi children at dispatch**: Replace `agents.ts::normalizeModel` pins with parsing. Use `settings.ts::selectedModelForAgent` and shared runner/pane preparation to pass parent registry and child directory to core before spawn. Preserve source/effort precedence. With kendex missing, preserve native inherit and an exact model found in the authenticated Pi registry. Refuse all other requests with one resolver-missing diagnostic naming kendex as the fix. Do not copy the parser or table. With kendex present, send all intent through core. Proof: both forms cover unavailable providers, unknown-evidence defaults and new registry families.
11. **Update docs, renders and release records**: Update the paths in the file list below. Cite D021 from architecture, without restating its rationale. Keep `agents/*.md` on inherit unless a specific source change is needed. Apply source diffs to the tracked renders by replay, not by copying files or running refresh/apply. Add a consumer changelog fragment with one item of at most 200 characters. Pi release entries use a heading naming the actual new version, not Unreleased. Proof: selected documentation, render-inventory, model tests and repository guard lanes pass through the authorized runner.
12. **Return receipts and hand off acceptance**: Report code/test coverage, real harness-list evidence, native-default fallback receipts and any refused integration path to the orchestrator. The fleet overseer schedules the trial below. The owner design/build answer is recorded. Do not mark the issue complete before implementation review, authorized validation, CI proof and the trial table.

## Proof

No implementation, test, build, install or render command runs in the design stage.

| Test owner and fixture | Claim it proves | Must-fail control |
| --- | --- | --- |
| Core/CLI item-selection correction | No size/risk mapping remains; explicit standard/top requests retain compatibility | Restore the removed size/risk path on a disposable copy; its rejection fixture fails. Explicit standard/top fixtures still use independent expected classes. |
| Overseer/lane selection and brief fixtures | Default items request standard; top requires a preserved item-specific reason, never an estimate | Substitute top for the default standard request while keeping launch code; its argv fixture fails. Review the reason-bearing label/brief and recovery cases against § Default selection. The general resolver does not judge prose. |
| Core model suite | fast on Claude-only inventory selects light and visits each row once | Remove fallback advancement on a disposable production copy; its fast fixture must fail. Separate control permits a repeated class and fails the termination test. |
| Core model suite | Selection never leaves the admitted provider/account inventory | Bypass the inventory intersection while keeping the candidate text; an OpenAI-only fixture must fail when Claude is selected. |
| Core model suite and collectors | Failed discovery stays distinct from empty/unsupported evidence; native default launches with failed-source causes | Turn `Failed` into `Complete([])` while retaining collection code; the evidence-tag/source assertion must fail. Separately turn failed evidence into permission to select an unverified table member; its selected-action assertion must fail. |
| Core and CLI suites | Unsupported, failed and complete-empty lists with native default succeed; confirmed no usable path refuses | Restore a refusal for each unknown-evidence state while keeping its diagnostics; each success fixture fails. Separately let a confirmed no-model fixture succeed; its refusal assertion fails. |
| Core and CLI suites | Unknown access/capacity never fabricates an id, class or capacity, including exact pins | Replace native default with the preferred table id; the absent-id/action fixture fails. Separately make an unknown pin exact or label fallback as a confirmed class; each tag/evidence fixture fails. |
| Core model suite | A generic singleton provider serves each class with an unclassified warning | Remove terminal default selection; the unknown-provider fixture must fail. |
| Manifest and CLI suites | A one-line override wins but never creates access | Ignore the parsed override; selected-id assertion fails. Separately bypass override availability and expect the unavailable-override case to fail. |
| CLI and render warning collector | Confirmed exact pins stay exact; unknown pin evidence uses native default; one warning retains request and source causes | Suppress the old-id cause; count/key assertion fails. Separately bypass the warning latch or drop the failed-source cause; each fixture fails. Pin keys/counts, not prose. |
| Family matcher and native alias tests | A newer available family wins; a Claude alias is still passed as an alias | Select the oldest available version; the newer-list case fails. Separately replace native sonnet with an old pin and expect its alias assertion to fail. |
| Renderer readback per changed surface | Only a native-valid model representation reaches disk | Plant an unsupported canonical class in a native model field; loader validation must fail. The Pi surface instead fails when the retained class is prematurely pinned. |
| Core agent-intent reader and CLI | A declared Claude child retains its original class and override precedence despite an alias render | Substitute the projected alias for the source request; the fast-with-sonnet-render case fails. Separately ignore the project override and expect the scoped-child case to fail. |
| Claude native `agent.spawn` suite | The selected selector comes from core before child startup; inherit/exact/unmanaged retain their rules | Restore the rendered model after core selects fallback; the spawn result fails. Separately convert a managed read failure to unmanaged and expect the denial case to fail. |
| Claude native `turn.step` suite | Root requests use core's selector; child requests and explicit native model changes are not forced to the root class | Forward the original root model instead of the selected one; the streamed-request case fails. Separately remove the child exclusion and the explicit-change check; each independent fixture must fail. |
| Claude native spawn/root suites | Unknown access/capacity preserves native parent/default selection even without an observable id | Return denial on unknown evidence while keeping diagnostics; each callback's forwarded spawn/request fixture fails. Separately retain the child's unconfirmed rendered alias instead of native inheritance; its selector assertion fails. Each callback tests a failed metadata read too. |
| Claude callback error suites | Core CLI failure, timeout, malformed core protocol and invalid result stop the covered request; model-evidence read failure falls back | Remove fail-closed `.catch` behavior while keeping registration text; inject an integration failure and assert zero downstream calls. Separately route a metadata-read failure into denial; its default-forwarding fixture fails. Each changed callback has its own controls. |
| Claude warning-state suite | Spawn/root callbacks and reloads share one warning latch with the managed launcher | Reset warning state on reload or ignore the launch latch; each warning-count fixture fails. |
| Claude launch suites | Known missing, disabled, old-version or wrong-host mod setups open no class session | Bypass the mod-readiness refusal while retaining its diagnostics; the no-launch fixture fails. |
| `lanes` fleet and named-lane suites | Both pick forms measure the selected native model and retain account scoring | Feed the requested class to `with_lane_binding` instead of the selected selector; the scoped-window fixture fails. |
| `lanes` fleet/named-lane and launch suites | Missing model evidence or capacity keeps the same account's native default; a known account wall still blocks | Restore `lane-provider-unmeasured` or unknown-model refusal on default fallback; each pick/launch fixture fails. Separately bypass a known account wall via default; its no-launch fixture fails. |
| Overseer and terminal preference suites | The launched selector is the one the shared pick returned | Restore an original entry model after the pick; its launch-argument assertion fails. |
| Overseer, terminal and Pi child suites | Native-default results launch without inventing a model argument or needing a default-id probe | Insert a table id when the result has no selector; each changed launch surface's argv fixture fails. Separately require an id and restore refusal; each default-start fixture fails. |
| Pi background and pane suites | Both child paths call the core owner and use current runtime availability | Bypass resolution in each changed spawn surface on a disposable copy; its child-argv assertion fails. |
| Context adapter, launch and handoff suites | Unknown capacity stays unknown and launches native default; known capacity belongs to the actual model | Restore alias-to-version pinning, guess a window, borrow the previous model's capacity or restore unknown-capacity launch refusal; each independent rule's fixture fails. Handoff fixtures assert unknown measurement, not a false measured threshold. |

Use `crates/test_util.rs` for Rust integration fixtures, `skills/orch/tests/lib/assertions.sh` for shell assertions and the existing Pi test helpers. Rust fixture roots are canonical. Real child processes get explicit fixture environments. Add Rust integration modules to the existing `tests/main.rs` owners.

Protocol fixtures prove payload handling, not live access, alias freshness or precedence. `claude plugin test` stubs events/API calls without a session, sign-in or network. Consume streams completely and assert downstream call counts; hook skips do not prove refusal. `claude plugin validate` proves structure and declared events/API calls only. Run both after authorization through the existing runner.

Real harness smoke checks must record the harness version, source interface, actual returned models and confirmed launch selector or native-default action. Retain failed-source diagnostics where list evidence is unread. Claude receipts additionally name mod loading, agent identity, child working directory, returned selector precedence, default/inherit forwarding and the root integration refusal. Record unknown access/capacity separately from confirmed no-model or account walls. Use disposable worktree-local plugin copies for generated native declarations. A missing login is skipped live evidence, not a passing access test. No test calls a paid model only to populate availability.

Run future checks only through `dev-validate-run` or the orch job runner. Unset `TMPDIR`, `ORCH_STATE_DIR` and `KENDEX_SKILL_LOAD_HOOK`. Give worktree-local state paths where supported. Select suites through existing suite entry points and dependency inputs; incomplete selection evidence runs the complete requested area. The retained combined FULL run failed at `tmp/dev-validate-20261002T045649Z-1539481` in the Original worktree. Catalog passed. No KEN-2464 exception applies to that receipt. P3 permits scoped required proof and one configured RANGE after all domain edits. CI supplies full proof. An actual test, runtime or validation failure stops this round and returns its exit and log to the owner before repair.

## Files

### Existing files to modify after authorization

| Area | Files or symbols |
| --- | --- |
| Core owner | `crates/core/src/harness/models.rs`, `models/tests.rs`, explicit item policy; `model_shape` and `effort_levels` only for native projection |
| Manifest and engine | `crates/core/src/manifest/mod.rs`, `manifest/validate.rs`, `manifest/tests.rs`, `manifest/validate/tests.rs`, `engine/desired_agent.rs::{effective_agent,agent_model_request}`, `engine/mod.rs`, `render/agent/mod.rs::{EffectiveAgent,merge_overrides}` and the shared `EffectiveAgent::model_request` reader and `crates/core/src/hash.rs::installation_hash` with its tests |
| Renderers and validation | `crates/core/src/render/agent/{claude,codex,copilot,pi,opencode,gemini,antigravity,cursor}.rs`, `render/validate/agent.rs`, `render/validate/tests.rs` |
| CLI | `crates/cli/src/commands/tier_model.rs::{TierModelArgs,run}`, `crates/cli/src/lib.rs`, `crates/cli/tests/tier_model.rs`, its existing roster and `snapshots/help/kendex-tier-model.txt` |
| Account and launch owners | `skills/orch/scripts/lanes`, `scripts/lib/lane-model.sh`, `scripts/lib/overseer-launch.sh`, `scripts/lib/lane-launch.sh`, `scripts/lib/lane-context.sh`, `scripts/lib/adapters/claude.sh`, `scripts/open-terminal` |
| Orch docs | `skills/orch/README.md` resolution/fallback and mod loading; `workflows/oversee.md` separates workflow sizing from standard/top choice and owns the top-reason brief; `references/lane-directive.md` carries that reason on recovery; `schemas/lane-host.md` tagged list/default evidence; `DEVELOPMENT.md` tests/version/policy limits. Default-ladder examples belong to the separate item. |
| Pi dispatch | `pi-extensions/pi-agents-tmux/extensions/subagent/{agents,settings,runner,pane}.ts`, common dispatch preparation, package README, DEVELOPMENT and versioned CHANGELOG |
| Architecture and authoring | `docs/architecture/harnesses.md` invariant 8, native callback and native-default boundaries; `docs/architecture/engine.md` shared render/runtime intent reader; `docs/authoring/settings.md` override/exact-pin known/unknown behavior; `docs/authoring/README.md`; `docs/adapters/claude.md` native mod loading/version/policy limits and unknown-capacity fallback; other affected adapter model dialects |
| Guards and generated types | `tools/guard` render_blind inputs and `models.rs` parity test; `ui/src/bindings.ts` through the existing binding generator if the exported Manifest type changes; read `tools/AGENTS.md`, app and UI instructions before those later edits |

### New implementation files

- `crates/core/src/harness/models/codex.rs` and `models/evidence.rs` for the separate protocol/evidence inputs. Keep class and family decisions in `models.rs`.
- `skills/orch/tests/model-classes.sh`, using the existing test library.
- `skills/orch/scripts/copilot-lane-context/model-list.mjs` and `skills/orch/tests/copilot-model-list.sh`. The helper uses the harness-shipped SDK only and feature-detects it. An absent SDK path is an explicit unsupported-list result.
- `skills/orch/scripts/claude-model-classes/.claude-plugin/plugin.json`, `hooks/hooks.json` and `hooks/register.js`, with tracked `.agents/skills/orch/` counterparts. No class members or fallback order live in these files.
- `skills/orch/scripts/claude-model-classes/tests/agent-spawn.test.ts` and `turn-step.test.ts`, run by the native mod test kit. Tests under a skill's `scripts/` tree render with it, so their matching tracked copies ship too. Add the native-kit suite to the existing authorized test entry point, not a second runner.
- `skills/orch/tests/claude-model-classes.sh` for managed launch loading and protocol transport, using the existing shell assertion library.
- Pi class-resolution tests under `pi-extensions/pi-agents-tmux/tests/`.
- `changelog.d/added/model-classes.md`.

Execution depends on `models.rs`, `commands/tier_model.rs`, `scripts/lanes`, `lib/overseer-launch.sh` and `scripts/open-terminal`. Add no Pi package, provider client, daemon, model cache, account probe or `.kendex-lock.json`.

### Source and render pairs

- Each changed `skills/orch/scripts/...` and shipped orch document pairs with the corresponding `.agents/skills/orch/...` entry already tracked by `.kendex-generated.json`. Top-level `skills/orch/tests/` and DEVELOPMENT are not rendered. Native mod tests below `scripts/claude-model-classes/tests/` render with that directory.
- A changed `agents/<name>.md` pairs with its tracked harness renders in the inventory. No frontmatter mass conversion is planned because catalog agents already inherit.
- Pi dispatch source belongs to its package. Only its declared generated bundle, if any, is regenerated through that package's existing build under the authorized runner. No catalog refresh creates it.
- Claude mod files and their tracked orch renders remain byte-matched through source-diff replay. The native loader's `.claude-plugin/types/` output belongs only to disposable validation copies.
- A new tracked render requires a sorted inventory entry. Leave the main install record unchanged.

## Risks and rollback

| Risk and reach | Mitigation |
| --- | --- |
| A restored size/risk mapping selects a class without an item reason | Keep explicit model requests and the existing Top model reason. The rejected helper remains absent. |
| Until the separate ladder item ships: fleet defaults can still start Fable/Astra | Keep that edit outside this branch and coordinate deployment. Resolver integration alone does not prove standard is the active default. |
| Whenever model access evidence is absent or unread: the native default may not meet the requested class | Launch the harness's own default/session model with one warning naming the unconfirmed class and failed source. Keep any id/class unknown. No unverified table member or new probe fills the gap. |
| Certain for direct Codex/Copilot independent class requests: static files cannot call the resolver | Use the owner-accepted managed-session boundary. Refuse unsupported independent requests. |
| Certain when the Claude mod is unloaded, disabled, too old or policy-blocked: callbacks do not enforce selection | Managed class launch refuses known unsupported setups. Direct users explicitly load the shipped mod. State the native-only boundary for other sessions. |
| Possible when a Claude callback has an integration failure: the platform skips it by default | Use native-valid `.catch` refusals for integration failures. Evidence-read failures instead warn and forward native default. Prove both downstream-call behaviors with native fixtures. |
| Possible with another model-changing Claude mod: a later handler changes the chosen selector | Require native precedence evidence for the supported configuration. Report conflicting mods as unsupported. Do not claim universal priority. |
| Possible after a provider release: a changed id grammar is not recognized | Treat it as unclassified, select only an admitted default and warn. Change the one matcher if the provider documents a new family format. |
| Possible after policy changes: a listed model later rejects the first turn | Stop with the native cause. Re-resolve only on a new complete list. Never retry through invented access. |
| Certain where the Claude alias resolves through an older gateway recommendation | Name that boundary in docs. Do not claim a static pin or native alias always means newest worldwide. |
| Possible on an unfamiliar provider: terminal fallback is weaker or more costly than the requested class | Emit unclassified/fallback causes. The consumer replaces one row with an available model using the one-line override. |
| Possible when two sessions use the same account: render rewrites would race | Write no runtime selection into committed or shared agent files. Keep list and warning state within the owning process. |
| Possible for a new Claude model or a first launch: missing capacity prevents a measured context handoff threshold | Use native default/session selection and warn. Keep capacity unknown until model-bound native metadata arrives. Preserve context actions on confirmed limits. Do not borrow a previous window or claim an unmeasured threshold passed. |
| Possible with a complete empty list: treating it as no-model blocks a usable native default | Carry the native default path separately. Refuse no-model only when all explicit and native paths are confirmed unusable. Known policy denial or an account wall cannot be bypassed through default. |

Rollback removes the class-aware caller changes, the Claude mod directory and its launcher flags/intent transport. Direct consumers remove its configured plugin-directory entry. Restore the previous tagged release's native launch/render behavior while retaining KEN-2468's no-Haiku substitution. Preserve usable native default/session launches. Restoring size/risk promotion, an unjustified top default or an unknown-evidence launch gate is not a valid rollback of the owner amendments. Do not replace default with an unverified old pin. Preserve consumer manifests. Consumers using `model-classes` remove that additive section before selecting an older binary that does not read it. No migration or shared account state needs reversal. Future rollback work goes through the normal authorized render path, not this lane's refresh/apply.

## Acceptance dependency and TPM handoff

Completion depends on the core correction, runtime integration, review, authorized validation, CI receipts and the fleet-owned vg trial. Coordinate the separately owned ladder-default deployment before fleet-default acceptance. Run standard for 72 hours and compare with the prior 72 hours. Post stage times, rework rounds, owner corrections and cost on KEN-2466. State missing measurements. Standard is already chosen; a later change needs an owner ruling.

A TPM handoff is needed only for coordination of the separately owned ladder work and an unscheduled fleet trial. KEN-2466 remains the design/build item. KEN-2468 remains interim history. Create no duplicate item or guessed issue id.

Prompt for the calling agent to pass to TPM:

> Keep KEN-2466 as design/build under D021 and docs/plans/model-class-resolution.md. The owner chooses standard now and requires an item reason for top. The separate item owns the standard/no-Fable/no-Astra ladder-default edit. Coordinate its deployment and the fleet-owned vg trial if needed; do not duplicate its edit or invent its id. Preserve KEN-2468's interim history. Track implementation review, authorized validation, CI, default deployment and the trial table as acceptance dependencies.

## Handoff prompt

> Implement KEN-2466 under amended D021 without another owner read. Read this plan/evidence completely. The rejected size/risk helper and its CLI inputs are already absent. Preserve explicit model requests. Use existing --model selection: standard by default, top only for an item-specific label/brief reason recorded by the overseer. Keep GPT-6.1 Sol on Astra's former default tasks, the top row, aliases, class overrides and fallback. Integrate the resolver into the existing ladder consumer, but do not edit OL_DEFAULT_PREFERENCE or default-list examples/assertions; KEN-2496 owns the actual ladder-default edit. Unknown access/capacity keeps launchable HarnessDefault without an id. Preserve account walls and integration refusals. Follow the ordered plan, proof and source/render rules. Record the ruling in the PR body. Use only authorized validation routing. No sync --reconcile, refresh/apply, base writes, lock changes or .kendex-lock.json. Return interface blockers, receipts and acceptance handoff. Do not run or invent the trial.

## Sources and evidence

Official source citations, retrieved evidence, measurement limits and design history are in [model-class-resolution-evidence.md](model-class-resolution-evidence.md#sources-and-evidence). The requested GPT-6.1 Luna and Terra releases remain unverified owner policy. No inventory gains a manufactured id.

During implementation add `REVISIT(D021)` markers at the class/fallback owner, the Claude mod version/policy boundary, the deferred native-render boundary and the alias/capacity boundary.
