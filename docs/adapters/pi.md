# Pi

The only harness with an extension kind kendex installs end to end, and the only one whose tool surface is deny-only over an open vocabulary, so an allowlist is refused. Owner: `crates/core/src/harness/pi.rs`.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.pi/agent` | `PI_CODING_AGENT_DIR` |
| Project | `<project>/.pi`, plus the shared `<project>/.agents` | nothing |

`PI_CODING_AGENT_DIR` is trimmed, `~` expands against the configured home, and the override is used only when it is anchored to a named root: a drive or UNC share on Windows, a leading `/` on POSIX. Empty, whitespace-only, relative and driveless-rooted values fall back to `~/.pi/agent`. `pi_root_is_absolute_for` in `crates/core/src/harness/pi.rs` is the rule, and every standalone Pi package's runtime readers carry their own copy, held to the Rust source case by case by the pi-hooks suite. The `scripts/append-system.mjs` install helpers are outside it: they resolve the variable as given, at install time, into a directory that already exists.

Project markers: a `.pi/` or `.agents/` directory.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | `~/.pi/agent/agents/*.md` | `.pi/agents/*.md` | managed, both |
| skill | `~/.agents/skills/<name>/SKILL.md`, shared with Codex, OpenCode, Gemini and Copilot; `~/.pi/agent/skills/<name>/SKILL.md` for a copy delivery | `.agents/skills/<name>/SKILL.md`, shared with Codex and Antigravity | managed, both |
| command | `~/.pi/agent/prompts/*.md` | `.pi/prompts/*.md` | managed, both |
| hook | `~/.pi/agent/kendex/hooks/<name>.sh` plus `kendex/hooks.json` | `.pi/kendex/hooks/<name>.sh` plus `.pi/kendex/hooks.json` | managed, both; enforced while the `pi-hooks` carrier is registered |
| mcp-server | — | — | unsupported |
| plugin | — | — | unsupported |
| pi-extension | `~/.pi/agent/settings.json` `packages[]`, and `~/.pi/agent/extensions/*.{ts,js}` | `.pi/settings.json` `packages[]`, and `.pi/extensions/*.{ts,js}` | managed, both |

## Format

- Name rule `Any`; namespace separator `__`.
- MCP transports: none; Pi reads no MCP servers.
- Command file: the author's markdown installed byte for byte as `prompts/<name>.md`, the filename being the `/name` typed. Pi reads the same frontmatter keys a Claude command carries (`description`, `argument-hint`) and ignores the rest, and every `$` placeholder Claude expands (`$ARGUMENTS`, `$1`, `$2`) expands on Pi too, beside Pi's own `$@`, `${1:-default}` and `${@:N}`; a Claude ``!`…` `` shell inline reaches the model as text, said as a warning (`crates/core/src/render/validate/command.rs`). Discovery is non-recursive and only `.md` loads, so a namespaced name flattens to `__` and the `.disabled` rename toggle is safe. Project prompts load only once Pi trusts the project: a saved decision, `--approve`, or `defaultProjectTrust = "always"` for a headless run; and `.pi/prompts` is one of the directories whose presence makes Pi ask for that trust, so the first command kendex installs into a project that had none turns the question on. Pi's own `pi config` switch writes a `-prompts/<name>.md` row into that scope's `settings.json` `prompts` array; kendex's switch is the rename, and it does not read that row.
- Agent file: YAML frontmatter and a markdown body, `<name>.md`. Fields written: `name`, `description`, `deny-tools`, `allowed-subagents`, `model`, `effort`, `color`, `pane` (`crates/core/src/render/agent/pi.rs`). No frontmatter schema is enforced beyond the name rule.
- Model dialect: `fable` and `opus` omit the key (inherit); other tiers resolve to `openai-codex/gpt-6-astra`; a bare id with no `/` passes through with a warning (`crates/core/src/harness/models.rs`). An effort setting is written as its own `effort` key (`minimal`, `low`, `medium`, `high`, `xhigh`, `max`), which the `pi-agents-tmux` extension passes to the child as `--thinking`; a pinned model id also carries it as a `:<effort>` suffix. `off` or `none` writes no key, and an absent key runs the child at Pi's `defaultThinkingLevel`.
- Permissions: deny-only. `allowed-subagents` and `deny-tools` are resolved together: engineers delegate to `scout` by default and every other role is a leaf; `subagent`, `get_subagent_result`, `steer_subagent` and `stop_subagent` are always denied; `delegate_subagent` is denied unless delegation was declared; every agent but a `role: planner` denies `question`, and a `role: reviewer` agent also denies `tasks_write`. An `AllowOnly` intent is a hard refusal naming both fixes: an explicit `deny-tools` override for Pi, or dropping Pi from the agent's harnesses.

## Hooks

Pi executes nothing per hook itself. The `pi-hooks` carrier extension hosts native listeners, and hook content rides in the registry kendex renders one level under the root: `<root>/kendex/hooks/<name>.sh` plus `<root>/kendex/hooks.json`, keyed by Pi's listener names (`pi_listener`, `crates/core/src/harness/caps.rs`: `PreToolUse` to `tool_call`, `PostToolUse` to `tool_result`, `Stop` and `TaskCompleted` to `turn_end`, `SessionStart` to `session_start`). An event outside that map installs nothing on Pi, said as a note. The tests are `crates/core/tests/pi_carrier.rs` and the pi-hooks suite under `pi-extensions/pi-hooks/`.

The carrier's rules:

- Every key `pi_listener` can return is one the carrier dispatches, so a registration kendex labels enforced is one something runs. On each listener it runs every registration whose `matcher` covers the event, in the order the registry names them, so a catalog guard and a `[[custom-hooks]]` command of the person's own both fire; the carrier knows no hook's name in advance, and a custom hook has no file at all, so the registry is the only place it exists. Absent, empty and `*` matchers cover everything; anything else is a whole-string regex over the word Claude Code writes matchers against: the tool on `tool_call` and `tool_result`, said in Claude Code's words (`vocab.ts`, held by a test to `render::vocab::claude_tool_name`), and the session source on `session_start`, where Pi's `reload` is said as `resume` and its `new` and `fork` as `clear`. `Stop` and `TaskCompleted` take no matcher, so every `turn_end` registration covers the turn.
- Only `tool_call` gates. Exit 2 is the refusal and its stderr is what the agent reads. Every other nonzero status blocks too, under a reason the carrier writes: a hook exiting 1, a failed spawn, a run past its budget, a registry that exists and cannot be read, and a rendered hook the registry names whose script no scope holds are all a guard that reached no verdict, and a guard that did not run does not stand aside. Only an absent registry allows, because that is kendex having installed nothing. Only exit 0 reaches the next registration; stderr beside it is an advisory for the person.
- Pi refuses nothing on the other three listeners, so a hook's word is delivered rather than obeyed, through the one channel each has: `tool_result` appends it to the tool result the model reads, `turn_end` steers it into the run with `sendMessage(..., { triggerTurn: true })` so a headless session answers for it in the next turn, and `session_start` adds it to the session's opening context without holding the session open. Every registration runs, since nothing is left to refuse. Exit 2's stderr is the word, exit 0's stdout is, and any other status, a budget overrun and a missing render included, is reported rather than read as an all-clear.
- `turn_end` is the registry key and `agent_settled` is the listener the carrier reads it on: Pi's own `turn_end` fires once per LLM turn inside the tool loop, while `Stop` and `TaskCompleted` mean the agent has finished responding, which is what Pi documents `agent_settled` as, so a request taking ten tool-calling rounds consults these registrations once. The steer that carries their word makes the agent answer and that answer settles in its turn, so the steer is spent once per consultation: the dispatch it caused reports without steering again and its payload says `stop_hook_active: true`, the field a `Stop` hook reads on Claude Code. A response reaches at most two dispatches whatever a hook says, so a registry that will not parse or a render that is gone cannot drive an unattended session.
- The carrier's own end-of-turn clippy check and session-start drift report are independent of the registry: they port catalog hooks whose `harnesses:` line leaves Pi out, so nothing registers them for Pi and nothing doubles. A person who installs their own copy gets both, and one setting (`taskCompletedCheck`, `sessionDriftCheck`) turns off both.
- A hook kendex rendered is spawned at `<root>/kendex/hooks/<name>.sh` under the root whose registry named it, never through the command that names it, so the rendered guards run the same bytes under Claude, Codex and Pi; any other command is the person's own and runs through a shell as written.
- The carrier resolves the project with `discover.rs::project_root_from`, not the adapter's two markers: the lock file wherever it stands, home included, else the nearest ancestor carrying one of the seven `MARKER_DIRS`, and home itself is never a project otherwise. That is what kendex asks before it renders, so the carrier reads where the renderer wrote.
- The project's registry is read only where Pi reports the workspace trusted; Pi saves that decision for the folder or any parent. Untrusted or outside any project, the project scope contributes nothing and the global root still answers.

Enforcement is read live (`enforcement`, `crates/core/src/pi_ext/carrier.rs`): with the carrier registered in either scope's settings the hook is enforced; with no carrier anywhere Pi loads, the install downgrades to advisory, said per item.

Reserved names: Pi warns on two directory names directly beside a root it loads and halts an interactive start until a keypress, `hooks/` on the name alone and `tools/` when it holds entries beyond Pi's own `fd` and `rg` binaries and dotfiles. kendex keeps scripts and registry under `kendex/` (`HOOK_HOME`, `crates/core/src/harness/pi.rs`) and writes nothing to `tools/`; an extension's `bin` entries link into the scope's `bin/`.

Beside the root, kendex does nothing at all: `engine::targets::pi_hook` names only `<root>/kendex/hooks.json`, `engine::owned::hook_owned` derives only `<root>/kendex/hooks/<name>.sh`, `harness::pi::hook_surfaces` lists only the first, and the carrier reads `<root>/kendex/hooks.json` alone. A `hooks.json` or `hooks/` directly beside the root is read, written, scanned, listed and removed by nothing, `kendex remove` included, and enforces nothing.

Agent scoping: none; only `agents = "all"` custom hooks are enforced, carrier permitting, and scoped ones render as advisory prose in the agent files.

## Pi extensions

An extension is an npm-shaped package a source ships under `pi-extensions/<name>/`. kendex copies it into the scope's `packages/` directory, resolves its production dependencies with npm (`--omit=dev --package-lock=false --legacy-peer-deps --no-audit --no-fund`), links its `bin` entries into the scope's `bin/`, registers it in the scope's `settings.json`, and mirrors its `pi.appendSystem` file into the scope's `APPEND_SYSTEM.md` as a marker block (`crates/core/src/pi_ext/`).

The same package under two names or at two scopes registers twice and crashes Pi at startup, so kendex checks for the duplicate before writing (`duplicate_elsewhere`, `crates/core/src/pi_ext/renames.rs`). Catalog packages live under the `@vanillagreen/` npm scope, and `RENAMES` in the same file maps every current name to each name an install or lock may carry for it, so an install under another of its names is recognized rather than reinstalled beside itself.
