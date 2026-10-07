# D021: Resolve model classes through one availability-aware owner

[← Decision Index](INDEX.md)

**Date**: 2026-10-01

**Status**: Active

**Research**: [KEN-2466](https://linear.app/vanillagreen/issue/KEN-2466); the design and its evidence are attached to that issue

**Refines**: [D008](D008-copilot-agent-model.md), [D015](D015-copilot-compaction-handoff.md)

**Decision**: kendex owns one class table and one resolver, `crates/core/src/harness/models.rs`. The classes are `top`, `standard`, `light` and `fast`, with vendor family names as input aliases on those rows and no second ladder; the shipped table is selection policy, never evidence of access. The resolver restricts explicit candidates to the consumer's documented model inventory, walks lower rows then higher from the requested class, and on unknown access or capacity keeps the harness's native default or session model with one warning; it refuses only a confirmed absence of any usable model. Claude Code receives its documented family aliases, never a versioned pin; the orch skill's Claude mod, in a session that loads it with `--plugin-dir` or `CLAUDE_CODE_PLUGIN_DIRS`, resolves a declared child's class, and a root class request set in `KENDEX_MODEL_REQUEST`, through `kendex tier-model` at run time, and with no Claude model list the child keeps its own model with one warning, which kendex 1.12.0 first sends as core's own line; a managed launch does not load it yet, so it carries the alias alone and no runtime availability filtering ([claude.md](../adapters/claude.md) § Format). Codex and Copilot class renders inherit the managed session; Pi's child dispatcher resolves through core and copies no table. `inherit` stays distinct from every class. Overseers, successors and item lanes request `standard` by default, and an item requests `top` only where a label or an overseer-set brief field names why; the class is never derived from an estimate, a workflow size or a generic risk category. A manifest overrides one class row with `model-classes.<class> = "provider/model"`.

**Why**: One owner removes the separate Rust tier map, shell alias pins and Pi normalization map that could disagree on membership and fallback. Native aliases let the harness apply its own account and provider rules, and availability filtering avoids starting a consumer on a model selected only because kendex ships its name. A shared default stops size promotion: an item is not a top-model item because it is large.

**Rejected**: Vendor names as the public class names: `opus` would mean both a class and one vendor's family. Ranking providers by price or benchmark: no signed-in account or catalog supplies a portable ranking. Refusing on unknown access or capacity: blocks a first usable launch because metadata is missing. Rewriting generated agent files on every hook: races concurrent sessions and changes recorded renders.

**Revisit when**: A remaining native loader gains a documented runtime class or model callback, Claude changes its mod callbacks or supplies a selectable-model list, a newer Haiku becomes owner-approved, or the owner changes the standard default after trial evidence.
