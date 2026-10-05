# One capability table

Read before changing an adapter, the capability table, rendering, hook delivery or the Pi carrier.

## The approach

An adapter owns one harness's paths and rendering, and nothing else. What kendex may do on a harness comes from one capability table, `crates/core/src/harness/caps.rs`, read by core and the UI: op × scope, whether a hook the tool loads is executed or only read, the MCP transports it speaks, and the name rule its loader enforces. Hook delivery is decided once, in `crates/core/src/hook/delivery.rs`, by capability: registered, in the agent file, advisory, or not installable with the reason. Hook events have one vocabulary, Claude Code's names in `crates/core/src/hook.rs`; every other harness maps from it. The on-disk facts per harness are the reference pages under [../adapters/](../adapters/README.md).

## Why

Eight harnesses disagree about where files go, what a hook can do and what a name may contain. One table read everywhere means a renderer, a validator and a page never carry a literal that drifts from the others, and a capability the harness lacks is marked unsupported rather than shimmed into something the person would mistake for support.

## Rules

- Do read the table; never carry a capability literal in a renderer, validator or page. `crates/core/src/harness/mod.rs` holds the table to what each adapter observes.
- Do decide a hook's delivery in one place; `managed` never implies enforcement, and an advisory install says so in the plan preview, the report and the tool's card. Its machine-free half, `hook_reach`, judges the hook's own header against one harness's enforcement; `delivery` feeds it one installation's, and a package's supported-tools row (`crates/core/src/package/support.rs`) feeds it the capability table's, so that row is the package's declared support, never one machine's delivery.
- Do read every rendering back through the target harness's own loader rules inside plan preview, and refuse it there with the fix, for that harness alone.
- Do claim only the adapter's own namespace: a file belongs to the tool whose namespace it sits in, and a cross-read, such as Copilot reading Claude Code's skills, is an input to effective state, never a second installation.
- Do render skills as per-harness variants deduplicated by content hash; harnesses reading one physical directory form a surface group with one variant validated against every member's loader. The shared tree is `.agents/skills` under the scope's own root, and a harness that reads neither it nor its own directory gets a link onto it.
- Never shim a capability a harness lacks natively; mark it unsupported. Where a vendor stores one kind as another, such as a Codex command stored as a skill, the table names the stored kind and the lock records what was written.
- Never let a Pi extension enter a scope through `add`; it rides the `pi-hooks` carrier, and `crates/core/src/pi_ext/state.rs` is the one comparison of a Pi package's state.
- Never read content a tool ships with itself as the person's: `crates/core/src/vendor.rs` reads ownership off the plugin registry a plugin names, and vendor-owned content is scored by nothing and asked about nowhere.
- Model policy and evidence resolution share `crates/core/src/harness/models.rs`; unknown access or capacity keeps the harness's native default and invents no model.

## The canonical example

`crates/core/src/harness/cursor.rs`: the smallest adapter, naming its roots, project markers and surfaces, declaring the rule its loader enforces, and leaving every may-it-do question to the table. A new adapter copies it and adds one row per kind to the table.

## Decisions

A Copilot agent names no model, [D008](../decisions/D008-copilot-agent-model.md); a Copilot hook refusal reaches the model through the registered command, [D011](../decisions/D011-copilot-refusal-answer.md); model classes resolve through one owner, [D021](../decisions/D021-runtime-model-classes.md).
