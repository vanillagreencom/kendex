# Custom hooks, enforced wherever a harness can enforce them

## The problem, stated once

vstack has two hook worlds that share a vocabulary and nothing else.

**Installed hooks** (`ItemKind::Hook`, a catalog item) get the whole engine: `hook_target()` picks a script path and a registry per harness and scope, `ConfigEdit::UpsertHook` writes the registration idempotently, the event is mapped into each harness's own names, the matcher is said in each harness's tool vocabulary, the lock owns the artifact, the safety rules score the script, `Enforcement` tells the UI whether the thing actually runs, and disabling renames the script and reverses the registration.

**Custom hooks** (`[[custom-hooks]]` in the manifest) get none of it. They are rendered into agent files: natively into Claude's per-agent `hooks:` frontmatter block, and as prose (`hooks_prose`) everywhere else. They are never registered, never locked, never scored, and until this week Cursor dropped them silently. Their event is now validated against one vocabulary (`core/hook.rs::EVENTS`), which is the first thing the two worlds share.

The ask: make a custom hook *run* on Codex, Pi, Gemini and Copilot the way it runs on Claude Code — without two engines, and without claiming enforcement a harness cannot deliver.

## What is actually true per harness

Read off `caps.rs`, `targets.rs`, and the adapter pages. "Agent identity" is the question that decides everything below: when a harness runs a config-level hook, can the hook tell which agent triggered it?

| Harness | Hook surface vstack already writes | Enforcement | Per-agent hooks natively | Agent identity at runtime |
|---|---|---|---|---|
| Claude Code | `settings.json` → `hooks`, script in `hooks/` | Enforced | **Yes** — `hooks:` block in the agent file | n/a (the file *is* the scope) |
| Codex | `hooks.json`, script in `hooks/`, `[features] hooks = true` | Enforced (8 mapped events) | No | **Unverified** |
| Pi | `hooks.json` registry read by the `pi-hooks` carrier | Enforced *only while the carrier is registered* | No | **Unverified** |
| Gemini CLI | `settings.json` → `hooks`, script in `.gemini/hooks/` | Enforced (11 events, ms timeouts) | No | **Unverified** |
| Copilot CLI | one `*.json` per hook under `hooks/` | Enforced | No | **Unverified** — but it fires `subagentStart`/`subagentStop` |
| OpenCode | instruction file referenced from config | Advisory | No | n/a |
| Cursor | `.cursor/rules/*.mdc` — project scope only; no global surface exists | Advisory | No | n/a |

The four **Unverified** cells are the only real unknown in this plan, and they are answerable by reading each vendor's hook payload reference. They decide one branch, not the architecture — see *Agent scoping* below.

## The shape of the answer

> One hook model. Two authors. Three deliveries. The delivery is decided by a capability, never by the author.

### 1. One model — `HookSpec`

Today `hook::HookSource` (parsed from a catalog script) and `manifest::CustomHook` (typed by a person) describe the same thing in different words. Collapse them onto one internal type that the engine speaks, with the two authors as constructors:

```rust
pub struct HookSpec {
    /// Stable identity: the registry key, the lock key, the script name.
    pub name: String,
    pub event: String,              // always the shared vocabulary
    pub matcher: Option<String>,    // always in Claude's tool names
    pub body: HookBody,
    pub description: Option<String>,
    pub safety: Option<String>,     // advisory prose, catalog hooks only
    pub timeout: Option<u32>,       // seconds; Gemini multiplies by 1000
    pub harnesses: Option<Vec<HarnessId>>,  // None = every declared harness
    pub agents: HookAgents,         // today's manifest type, reused as-is
}

pub enum HookBody {
    /// vstack owns the file and writes it (catalog hooks).
    Script(String),
    /// The person's own command, registered verbatim (custom hooks).
    Command(String),
}
```

`Artifact::Registration` already carries `script: Option<...>`, so a command-bodied hook is an artifact with no script and the same edits. No new artifact kind, no second apply path.

Two deliberate reuses, not new types:

- `agents` stays `manifest::HookAgents` (`One(String)` matching `"all"`, a role, or an agent name; `Many(Vec<String>)`). Inventing an `All | Role | Named` enum would split what the manifest spells as one string, force a serialization migration, and gain nothing — the render matcher (`hooks_for_agent`) already resolves the string against role and name. Catalog hooks construct `One("all")`.
- `HookSource` already carries `name`, `timeout`, and `harnesses` — the spec's fields are its fields plus `HookBody`. The gap is entirely on the `CustomHook` side (today: `event`, `matcher`, `command`, `description`, `agents` — nothing else).

### 2. Two authors

| Author | Produces | Notes |
|---|---|---|
| Catalog item (`desired_kinds::desired_hook`) | `HookSpec { body: Script, agents: One("all") }` | today's path, unchanged in behaviour |
| Manifest `[[custom-hooks]]` | `HookSpec { body: Command, agents: … }` | new: goes through the same engine |

This is where the two worlds actually merge: `desired_hook` stops being "the hook path" and becomes one caller of `desired_hook_spec(spec, ctx)`.

### 3. Three deliveries

```
                     ┌─ agents = "all" ────────────────────────────┐
                     │                                             │
HookSpec ──► delivery(harness, scope, spec) ──► Registered  ← script/command in the
                     │                          (enforced)    harness's own hook file
                     │
                     ├─ scoped agents, harness takes per-agent hooks
                     │                       ──► InAgentFile   ← Claude's `hooks:` block
                     │                          (enforced)
                     │
                     ├─ scoped agents, harness cannot tell agents apart —
                     │  or the harness only reads hooks as text
                     │                       ──► Advisory      ← prose in the agent file,
                     │                          (said so)        matcher in the harness's
                     │                                           words, warning attached
                     │
                     └─ nothing to write here at all
                                             ──► NotInstallable ← installs nothing,
                                                 (with reason)     reason shown, never
                                                                   silent
```

One function decides, and every surface reads it:

```rust
pub enum Delivery {
    Registered,
    InAgentFile,
    Advisory,
    /// This harness × scope has no surface for this hook at all —
    /// e.g. Cursor at global scope (`hook_target` returns None), or an
    /// event no listener fires on Pi. Carries the reason as a note.
    NotInstallable(Note),
}

pub fn delivery(env: &Env, scope: &Scope, harness: HarnessId, spec: &HookSpec)
    -> Delivery;
```

`NotInstallable` is not decoration: without it the model cannot describe Cursor at global scope (no target exists) or an unmapped event on Pi (installs nothing today, said as a note — honesty over stale advisory prose, per the Pi decision in ARCHITECTURE.md). Three variants would force those cells to lie as `Advisory` when nothing renders.

`delivery()` composes four facts that already exist or are cheap to add:

1. `hook_target(env, scope, harness, name)` — `None` → `NotInstallable` (Cursor global today).
2. `harness::hook_enforcement(env, scope, harness)` (lives in `harness/mod.rs`) — the live answer, including Pi's carrier check. `Advisory` ends it here.
3. The event maps on this harness (`codex_event`, `pi_listener`, `gemini::event`, `copilot::event`). No map → `Advisory` when an agent file exists to carry the prose (custom hooks), `NotInstallable` otherwise (catalog behaviour today: Codex skips, Pi installs nothing with a note).
4. `agent_scoping(harness)` — the new capability, below.

### Agent scoping — the one new capability

```rust
pub enum AgentScoping {
    /// Hooks live inside the agent's own file (Claude Code).
    PerAgentFile,
    /// Every hook invocation names the agent, so one registration can gate
    /// itself. `field` is the JSON pointer into the payload.
    Payload { field: &'static str },
    /// Nothing identifies the agent: only `agents = all` can be enforced.
    None,
}

pub fn agent_scoping(harness: HarnessId) -> AgentScoping;
```

Claude is `PerAgentFile` today. Everything else starts at `None`, which is honest and ships immediately: **`agents = all` becomes enforced everywhere, named-agent hooks stay advisory off Claude and say so.** When the payload research lands for a harness, that harness moves to `Payload { … }` and gets the dispatcher below — one line in a table, no engine change.

**The dispatcher** (only for `Payload`): vstack writes a small generated wrapper next to the hook that reads the payload on stdin, compares the named field against the selector, exits 0 (no-op) when it does not match, and `exec`s the person's command when it does. Same file-and-registration mechanics as a catalog hook — it is a `HookBody::Script` synthesised from a `HookBody::Command` — so nothing downstream learns a new shape. This is the same trick the `pi-hooks` carrier already plays for Pi: a shim owns the mechanism, the content stays declarative.

## Identity, or: what breaks first

`[[custom-hooks]]` is an ordered array with no names. Registration demands stable identity — the registry upsert, the removal, the lock key, the disabled-file rename and the UI row all need to name *this* hook and not its neighbour. Positional identity means reordering the array silently re-registers everything.

**Add an optional `name` to `[[custom-hooks]]`, defaulting to a derived slug**: `command_stem(command)` + event, lower-kebab, de-duplicated within the scope (`guard-pretooluse`, `guard-pretooluse-2`). The derived name is written back on the first save so it stops being derived — the mechanism already exists: the editor persists through `Op::WriteManifest` (`app/editor.rs`), and the engine's `DesiredState::manifest_update` is the precedent for a plan writing derived facts back into the manifest. Lock keys then read `hook:<name>:<harness>`, indistinguishable from a catalog hook's, which is what lets one removal path serve both. (The observed-side scanner keeps its synthetic `{event}:{matcher}:{command_stem}` names — ownership is read from the lock's recorded paths and edits, never matched by observed name, so the two namings never need to agree.)

## Everything else this drags in

| Area | Today | After |
|---|---|---|
| Safety gate | custom hooks are **never scored as hooks** — the command rides incidentally inside the rendered agent file, which is scored as a document, so no hook rule ever reads it | scored as a hook (`Content::Hook` with the command), same rules, same block/accept flow. This is a bug fix regardless of the rest of the plan. |
| Lock | not tracked; nothing to remove when the entry disappears | owned artifact per harness; removal on delete, orphan cleanup included |
| Timeout | no field | `timeout` field, seconds, ms conversion for Gemini reused |
| Harness targeting | none — every declared harness | `harnesses` field, reusing `HookSource::applies_to` |
| Enable/disable | none | the existing `.disabled` rename + reversed registration |
| Advisory prose | always rendered on non-Claude | rendered **only** where delivery is `Advisory` — otherwise the hook is registered and the prose would be a second, weaker copy of the same rule |
| `hooks_for_agent` | selects hooks per agent for rendering | stays, but only feeds `InAgentFile` and `Advisory` deliveries |
| Drift | custom hooks invisible | registrations drift like any other, through the existing idempotent-edit check |

## Code, file by file

**Core, new** (`hook.rs` is a single file today; it becomes `hook/mod.rs` with these beside it)

- `core/src/hook/spec.rs` — `HookSpec`, `HookBody`, the two constructors, name derivation.
- `core/src/hook/delivery.rs` — `Delivery`, `delivery()`, `agent_scoping()`, the dispatcher script generator.

**Core, changed**

- `hook/mod.rs` — keep `EVENTS`, `known_event`; `HookSource` becomes a parser that yields a `HookSpec` (or is absorbed entirely). `custom_hook_enforced()` (Claude-only bool) is deleted — it is the one-cell precursor `delivery()` generalises, and keeping both would be two answers to one question.
- `engine/desired_kinds.rs::desired_hook` — split into "parse the catalog item into a spec" and `desired_hook_spec()`, then call the latter from both authors. Manifest custom hooks enter via a new `engine/desired_custom_hooks.rs` that iterates `manifest.custom_hooks`.
- `engine/targets.rs` — `hook_target()` unchanged; a command-bodied spec simply carries `script: None`.
- `render/agent/mod.rs` — `hooks_for_agent` filtered by delivery; `hooks_prose` unchanged (already translates the matcher).
- `render/agent/claude.rs` — the `hooks:` block only for `InAgentFile` deliveries, i.e. named-agent hooks. `agents = all` moves to `settings.json`, where it belongs and where it also covers the main session rather than only subagents.
- `manifest/validate.rs` — validate `name` uniqueness, `timeout` range, `harnesses` membership; event validation already landed.
- `quality/observe.rs` + `engine/gate.rs` — score command-bodied hooks.
- `harness/caps.rs` — `agent_scoping()` table beside the `Enforcement` rows (`hook_enforcement()` itself lives in `harness/mod.rs` and is unchanged).

**App / UI**

- `app/editor.rs::EditorInventory` — `hookEvents` stays; `hookEnforcedBy` (hardcoded `["claude"]` via the deleted `custom_hook_enforced`) is **replaced**, not extended, by a per-harness delivery preview for the hook being edited, computed by `delivery()`. Bindings regenerate (`cargo test -p vstack-app -- --ignored regenerate_bindings`).
- `ui/src/lib/copy-customize.ts` — the three strings that carry today's story (`hookRunBy` "Claude Code runs these.", `ADVISORY_EVERYWHERE_ELSE` "…which nothing enforces.", `HOOKS_HELP`) are rewritten to read the delivery preview. Consumer copy, per hook: *"Runs in Claude Code, Codex and Gemini · written as guidance in Cursor"* — "runs" for enforced deliveries, "written as guidance" for advisory, "can't run here: <reason>" for not-installable. No hedging, no mechanism words (registration, frontmatter, prose) on screen.
- Custom hooks editor (`ui/src/components/customize/custom-hooks.tsx`): name field (prefilled from the derived slug, editable), timeout, harness picker, and the delivery line above — all computed, never hardcoded prose.
- Review & apply: custom-hook registrations appear as ordinary planned ops.

**Docs**

- `docs/adapters/*.md` — an "Agent scoping" line per harness page.
- `docs/adapters/pi.md` — already stale (still says hooks unsupported, contradicting `caps.rs` and the shipped carrier); correct it in phase 1 rather than building on a page that lies.
- `ARCHITECTURE.md` — the delivery rule as an invariant: *a hook's delivery is decided by a capability, and every surface reads the same decision*.

## Phasing

Each phase ships on its own and leaves the app honest.

1. **Identity and parity fields.** `name`, `timeout`, `harnesses` on `[[custom-hooks]]`, validation, name derivation and write-back. No behaviour change yet. Fix the stale `pi.md` here too.
2. **Score them.** Custom hook commands go through the safety gate. Pure bug fix; no new surfaces. (After phase 1 deliberately: decisions bind to `kind:name:harness` tokens, so findings need real names first.)
3. **One spec, one engine — and the UI stops saying "nothing enforces" in the same change.** Introduce `HookSpec` + `delivery()`, route catalog hooks through it unchanged (tests must not move), then route `agents = "all"` custom hooks into real registrations. The delivery preview replaces `hookEnforcedBy` and the copy-customize strings *in this phase*: the moment a hook actually runs on Codex, the app must not still claim it is instructions-only. Behaviour and its label ship together or the app lies at a phase boundary.
4. **Finish the editor.** Name/timeout/harness fields, per-hook delivery line, disable switch, removal affordance.
5. **Named-agent enforcement**, per harness, as payload research lands: flip one table entry, generate the dispatcher, add that harness's row to the delivery test matrix.

Validation at each boundary, beyond the unit tests below: run the app, author a custom hook on the Customize page, apply, and read the plan preview + the harness's own config file — after phase 3 the Codex `hooks.json` entry must exist and the Claude agent files must not have grown a second advisory copy. `vstack check` must come back clean immediately after the apply (no self-drift).

## Tests

- **Table test over (harness × scope × selector × event)** asserting the `Delivery` each combination gets — the single place this design can rot.
- Catalog hooks render byte-identically before and after phase 3 (golden test over the existing fixtures; the refactor must be invisible).
- `agents = all` custom hook on Codex writes the script-less registration, and removing the manifest entry removes the registration.
- A named-agent hook on a `None`-scoping harness renders prose *and* a warning, and writes no registration.
- The cells with nothing to write are `NotInstallable` with a reason — Cursor at global scope, an unmapped event on Pi — and install nothing, silently nowhere.
- The editor's delivery line is asserted against `delivery()` output, not a string literal, so the two cannot drift.
- Name derivation is stable and collision-free; reordering the array changes nothing on disk.
- A custom hook whose command carries `curl … | sh` is blocked by the gate exactly as the same command inside a catalog hook's script is.
- Dispatcher (when a harness reaches `Payload`): matches the named agent, exits 0 for others, passes stdin through untouched.

## What this refuses to do

- **No shimming a hook system that does not exist.** OpenCode and Cursor stay advisory; vstack does not wrap their binaries or watch their files.
- **No guessing at agent identity.** A harness stays `None` until its payload is read from the vendor's own reference. A hook that fires for every agent when the person asked for one agent is worse than a hook that says it could not be enforced.
- **No second engine.** If a delivery cannot be expressed as `Artifact::Registration` or a file the agent renderer already writes, it does not ship.

## Open questions

1. Does Codex / Pi / Gemini / Copilot name the agent in a hook payload? (Decides phase 5 per harness. Everything else ships without it.)
2. Should `agents = all` custom hooks on Claude move out of the agent frontmatter into `settings.json`? It is the honest home — the hook then also covers the main session — but it changes what an existing user's agent files look like. Proposed: yes, with the change stated in the plan preview.
3. Does a custom hook need `safety` prose of its own, or is `description` enough for the advisory fallback? Proposed: `description` only, until someone asks.
