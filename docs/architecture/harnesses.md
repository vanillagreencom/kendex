# Harness adapters

Covers: crates/core/src/harness/, crates/core/src/render/, crates/core/src/scan/, crates/core/src/pi_ext/, crates/core/src/vendor.rs, crates/core/src/mapping.rs

An adapter owns one harness's paths and rendering, and nothing else. What kendex may do on a harness comes from one capability table read by core and the UI; the per-harness on-disk facts are in [../adapters/README.md](../adapters/README.md).

## Boundaries

- An adapter claims only its own namespace: a file belongs to the tool whose namespace it sits in, and a cross-read (Copilot reading Claude Code's skills) is an input to effective state, never a second installation. Enforced by `crates/core/src/harness/mod.rs::copilot_manages_only_the_surfaces_it_documents`.
- The capability table (`crates/core/src/harness/caps.rs`) is the one source for op × scope, whether a hook the tool loads is executed or only read, the MCP transports it speaks, and the name rule its loader enforces; renderers, validators and the surface model read it and never carry literals. Enforced by `crates/core/src/harness/mod.rs::observe_capabilities_match_declared_surfaces`, `::no_capability_exceeds_observation`, `::every_hook_row_says_whether_the_tool_runs_it` and `::mcp_transports_agree_with_the_mcp_row`.
- Hook delivery is decided once, in `crates/core/src/hook/delivery.rs`, by capability: `Registered`, `InAgentFile`, `Advisory` or `NotInstallable` with the reason; `managed` never implies enforcement, and an advisory install says so in the plan preview, the report and the tool's card. Enforced by `crates/core/tests/hook_promises.rs` and `crates/core/tests/custom_hooks.rs`.

## Invariants

1. Rendered skills are per-harness variants deduplicated by content hash; harnesses reading one physical directory form a surface group carrying one variant validated against every member's loader, and a variant whose bytes match the shared tree collapses onto it through a relative, committable link. A refusal is per surface. Enforced by `crates/core/tests/surfaces.rs`.
2. A surface is one of four shapes (`FileDir`, `SubdirPerItem`, `Structured`, `StructuredDir`); where entries inside a document are the items, a document holding none reports none. Enforced by `crates/core/tests/copilot.rs`; the empty-document case is not mechanically enforced.
3. Every rendering is read back through the target harness's own loader rules inside plan preview and refused there, with the fix, for that harness alone. Enforced by `crates/core/src/render/validate/tests.rs`.
4. The only kind stored as another is a Codex command, stored as a skill; the table names the stored kind and the lock records what was written. Enforced by `crates/core/src/harness/mod.rs::the_only_kind_stored_as_another_is_a_codex_command`.
5. Scoped hook enforcement exists only where a vendor's payload proves the agent is named at runtime; Claude carries hooks in the agent's own file and every other harness answers `None`. Enforced by `crates/core/src/hook/delivery.rs::only_claude_scopes_hooks_per_agent_today`.
6. Pi hooks are enforced through the carrier: the `pi-hooks` extension hosts native listeners and hook content rides in the registry kendex renders under a `kendex` directory beside it, keyed by Pi's listener names; every listener key `pi_listener` maps onto is dispatched, only `tool_call` gates, `turn_end` is read once per response on Pi's `agent_settled`, and Pi reserves `hooks/` beside every root it loads, so nothing writes a registry there. The rules in full are in [../adapters/pi.md](../adapters/pi.md). Enforced by `crates/core/tests/pi_carrier.rs` and `pi-extensions/pi-hooks/tests/registry.test.ts`.
7. A Pi extension never enters a scope through `add`: a request naming one is the typed refusal `PiExtensionDirect` and writes nothing. Enforced by `crates/core/tests/install_seam/main.rs::a_direct_pi_extension_add_refuses_naming_the_carrier`. Pi package comparisons share `crates/core/src/pi_ext/state.rs`. Ordinary reports require a matching completed install record. Before replacement, update-pi clears the recorded render hash but keeps source provenance; only successful installation restores completion. Refresh reports packages it cannot repair and names `update-pi`, which installs the package and records its current standing. Enforced by `crates/cli/tests/pi_staleness.rs`.
8. One model-alias table serves every harness (`crates/core/src/harness/models.rs`): bare tiers resolve per harness, `inherit` is expressed in each tool's dialect, explicit vendor ids pass through, and a model of the wrong shape or an effort level the harness does not accept is refused at render. Enforced by the tests in `crates/core/src/harness/models.rs` and `crates/core/src/render/validate/tests.rs`.
9. Content a tool ships with itself belongs to that tool: `crates/core/src/vendor.rs` reads ownership off the plugin registry a plugin names, an unknown registry is the user's, and vendor-owned content is scored by nothing and asked about nowhere. Enforced by the tests in `crates/core/src/vendor.rs`.
10. An agent's bytes come from its published file at the installed commit with the catalog's tables and the person's own overrides; a rendering restricting it further is refused. Enforced by `crates/core/tests/edits_and_forks/agent_tables.rs`.

## Decisions

- Every capability ships cross-harness through the table; a harness without native support for a kind is marked unsupported, never shimmed.
- A column exists in the table only if a verb reads it; what a tool's own config holds down (Copilot's `disabledSkills`) is reported per item where it is read, and kendex's own switch still works both ways because it is a rename kendex can undo.
- Every harness but Claude Code reads a project's `.agents/skills`, so one tree serves them all and copy delivery writes each harness's own directory; no harness caps a SKILL.md body.
- The drift-relaying hook is first-party, shipped in the binary, offered at project registration, never fetched from a catalog, and still a declared, user-approved per-scope install rendered and removed like any other hook. Enforced by `crates/core/tests/drift_hook_install.rs`.
