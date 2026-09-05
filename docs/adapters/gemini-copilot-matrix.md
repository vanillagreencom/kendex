# Gemini CLI and GitHub Copilot — observation matrix

The observation matrix behind the Gemini and Copilot adapter pages, cited from the code as `matrix §N`. Every claim below is checked against official documentation or upstream source; nothing rests on wshobson's adapters (see the discrepancy log).

Two upstream repos are the ground truth:

- Gemini CLI — `github.com/google-gemini/gemini-cli`, `docs/` on `main`, plus `packages/` source where docs are silent.
- Copilot — `docs.github.com/en/copilot`, whose markdown source is `github.com/github/docs` under `content/copilot/`. VS Code-only surfaces come from `code.visualstudio.com/docs/agent-customization/`.

---

## 1. Gemini CLI — observation matrix

Global root is `~/.gemini`. Project root is `<project>/.gemini`. The two scopes are symmetric for every file-backed kind.

| Kind | Supported | Project location | Personal location | Format / key fields | Enable / disable | Notes |
|---|---|---|---|---|---|---|
| **agent** | yes, both scopes | `.gemini/agents/*.md` | `~/.gemini/agents/*.md` | Markdown + YAML frontmatter. Required: `name`, `description`. Optional: `kind` (`local`\|`remote`), `tools` (array, wildcards `*`, `mcp_*`, `mcp_<server>_*`), `mcpServers` (inline object), `model` (or `inherit`), `temperature`, `max_turns`, `timeout_mins`. Body = system prompt | `agents.overrides.<name>.enabled: false` in settings.json; whole feature gated by `experimental.enableAgents` | `/agents` manages interactively. `kind: remote` points at an off-machine agent — treat as observe-only |
| **skill** | yes, both scopes | `.gemini/skills/<name>/SKILL.md`, alias `.agents/skills/<name>/SKILL.md` | `~/.gemini/skills/<name>/SKILL.md`, alias `~/.agents/skills/<name>/SKILL.md` | Directory per skill with `SKILL.md`; frontmatter `name`, `description` only. Optional `scripts/`, `references/`, `assets/` | `skills.enabled` (bool, whole feature) and `skills.disabled` (array of names) in settings.json; `/skills enable\|disable <name> --scope user\|workspace` | Precedence workspace > user > extension > built-in. The `.agents/` alias is shared with other tools — see risk R6 |
| **command** | yes, both scopes | `.gemini/commands/**/*.toml` | `~/.gemini/commands/**/*.toml` | TOML. Required `prompt`; optional `description`. Subdirectory becomes a `:` namespace (`git/commit.toml` → `/git:commit`). Placeholders `{{args}}`, `!{shell cmd}`, `@{path/to/file}` | No per-command setting. Only `.toml` is loaded, so a `.disabled` suffix rename is inert and safe | Project overrides user on name collision |
| **hook** | yes, both scopes | `hooks` key inside `.gemini/settings.json` | `hooks` key inside `~/.gemini/settings.json` | `{"hooks": {"<Event>": [{"matcher": "<regex>", "sequential": false, "hooks": [{"type": "command", "command": "...", "name": "...", "timeout": 60000, "description": "..."}]}]}}`. Events: `BeforeTool`, `AfterTool`, `BeforeModel`, `AfterModel`, `BeforeToolSelection`, `BeforeAgent`, `AfterAgent`, `SessionStart`, `SessionEnd`, `Notification`, `PreCompress` | Remove or edit the entry; no per-hook flag | Extensions ship their own at `<ext>/hooks/hooks.json`. Matchers are regexes over tool names |
| **mcp-server** | yes, both scopes | `mcpServers` key inside `.gemini/settings.json` | `mcpServers` key inside `~/.gemini/settings.json` | Map of name → `{command, args, env, cwd, url, httpUrl, headers, timeout, trust, description, includeTools, excludeTools}` | `~/.gemini/mcp-server-enablement.json` holds `{<server>: {enabled: bool}}` (global file, applies to all scopes); settings `mcp.allowed[]` / `mcp.excluded[]` also gate | Enablement state is **global-only** even for a project-declared server |
| **plugin / extension** | yes, **global only** | none — there is no project extension directory | `~/.gemini/extensions/<name>/` | `gemini-extension.json`: `name`, `version`, `description`, `mcpServers`, `contextFileName`, `excludeTools`, `migratedTo`, `plan`, `settings[]`, `themes[]`. Layout: `commands/`, `skills/`, `agents/`, `hooks/hooks.json`, `policies/`, `GEMINI.md`, `.env` | `~/.gemini/extensions/extension-enablement.json` (path-scoped override rules, `!` prefix = disable, trailing `*` = include subdirs) and `extensions.disabled[]` in settings; CLI `gemini extensions enable\|disable <name> --scope <scope>` | An extension is installed once globally but can be enabled per workspace path. Confirmed global-only in `packages/cli/src/config/extensions/storage.ts` — `ExtensionStorage.getExtensionDir()` always resolves under the user extensions dir |
| **context / instructions** | yes, both scopes | `GEMINI.md` at project root and every ancestor up to a boundary marker (default `.git`), plus just-in-time discovery in subdirectories when a tool touches a file | `~/.gemini/GEMINI.md` | Markdown; `@file.md` imports (relative or absolute) | Rename the file, or change `context.fileName` (accepts a string or an array such as `["AGENTS.md", "CONTEXT.md", "GEMINI.md"]`) | `/memory show`, `/memory reload`. kendex has no ItemKind for this today |

Sources: [configuration reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/configuration.md) · [subagents](https://github.com/google-gemini/gemini-cli/blob/main/docs/core/subagents.md) · [skills](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/skills.md) · [creating skills](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/creating-skills.md) · [custom commands](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/custom-commands.md) · [hooks reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md) · [extensions reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/extensions/reference.md) · [GEMINI.md context](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/gemini-md.md) · [tools reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/tools.md).

### Settings precedence (matters for apply)

Later wins:

```
defaults
  → /etc/gemini-cli/system-defaults.json        (macOS /Library/Application Support/GeminiCli, Windows C:\ProgramData\gemini-cli)
    → ~/.gemini/settings.json
      → <project>/.gemini/settings.json
        → /etc/gemini-cli/settings.json          ← system OVERRIDE sits ABOVE project
          → environment variables
            → command-line flags
```

A value kendex writes into `.gemini/settings.json` can be overridden by the system layer. Env overrides for the two system paths are `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` and `GEMINI_CLI_SYSTEM_SETTINGS_PATH`. ([configuration reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/configuration.md))

### Built-in tool identifiers

Needed for any `tools:` allowlist kendex renders: `run_shell_command`, `glob`, `grep_search` (legacy alias `search_file_content`), `list_directory`, `read_file`, `read_many_files`, `replace`, `write_file`, `ask_user`, `write_todos`, `google_web_search`, `web_fetch`, `list_mcp_resources`, `read_mcp_resource`, `activate_skill`, `get_internal_docs`, `enter_plan_mode`, `exit_plan_mode`, `update_topic`, plus experimental `tracker_*`. ([tools reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/tools.md))

---

## 2. GitHub Copilot — observation matrix

Copilot is four products sharing filenames. kendex should treat **Copilot CLI + repository files** as the harness and ignore the rest; the columns below name which surface honors each row, because a file that only VS Code reads is not something a CLI-shaped adapter should claim to manage.

Global root is `~/.copilot`, relocatable by the `COPILOT_HOME` environment variable (and by the legacy `--config-dir` flag). Repository files live under `.github/`.

| Kind | Supported | Project location | Personal location | Format / key fields | Enable / disable | Surfaces |
|---|---|---|---|---|---|---|
| **agent** | yes, both scopes | `.github/agents/*.agent.md` | `~/.copilot/agents/*.agent.md` | Markdown + YAML frontmatter. Required `description`. Optional `name`, `tools`, `model`, `target` (`vscode`\|`github-copilot`), `user-invocable` (default true), `disable-model-invocation` (default false), `mcp-servers` (github.com only), `metadata` (github.com only). `infer` is retired | Frontmatter `user-invocable` / `disable-model-invocation`. `subagents.disabledSubagents[]` in settings disables **built-in** agents only. No documented per-custom-agent kill switch | CLI, VS Code, cloud agent. VS Code additionally reads `.claude/agents` and adds `argument-hint`, `agents`, `handoffs`, `hooks` fields |
| **skill** | yes, both scopes | `.github/skills/<name>/SKILL.md`; the CLI also reads `.claude/skills` and `.agents/skills` | `~/.copilot/skills/<name>/SKILL.md`; also `~/.agents/skills` | Directory per skill with `SKILL.md`. Required `name` (lowercase-hyphen), `description`. Optional `license`, `allowed-tools`. Sibling files auto-discovered | `disabledSkills[]` in `~/.copilot/settings.json` or `.github/copilot/settings.json` (union merge — repo may add, never remove). `skillDirectories[]` adds extra roots. `/skills list\|info\|add\|remove\|reload` | CLI, cloud agent, code review, VS Code, JetBrains |
| **command** | **unsupported** | — | — | — | — | Copilot CLI has no file-backed slash-command kind. The nearest thing, prompt files `.github/prompts/*.prompt.md`, is IDE-only (VS Code / Visual Studio / JetBrains), in public preview, and is not read by the CLI or github.com. Mark unsupported |
| **hook** | yes, both scopes | `.github/hooks/*.json`, plus a `hooks` key in `.github/copilot/settings.json` and `.github/copilot/settings.local.json` | `~/.copilot/hooks/*.json`, plus a `hooks` key in `~/.copilot/settings.json` | `{"version": 1, "disableAllHooks": false, "hooks": {"<event>": [{...}]}}`. Entry types: `command` (needs one of `bash`, `powershell`, `command`; optional `cwd`, `env`, `timeoutSec` default 30, `matcher` regex), `http` (`url`, `headers`, `allowedEnvVars`), `prompt` (`prompt`). Events: `preToolUse`, `postToolUse`, `postToolUseFailure`, `permissionRequest`, `userPromptSubmitted`, `userPromptTransformed`, `sessionStart`, `sessionEnd`, `preCompact`, `notification`, `subagentStart`, `subagentStop`, `agentStop`, `errorOccurred` (each also accepts a PascalCase spelling) | `disableAllHooks: true` — all-or-nothing, no per-hook flag. File-backed hooks can be toggled by rename | CLI and cloud agent. The cloud agent reads only `.github/hooks/*.json` |
| **mcp-server** | yes, both scopes | `.mcp.json` in any directory from cwd up to the repo root, and `.github/mcp.json` | `~/.copilot/mcp-config.json` | `{"mcpServers": {"<name>": {"type": "local"\|"stdio"\|"http"\|"sse", "command", "args", "env", "url", "headers", "tools"}}}` | `disabledMcpServers[]` in user or repo settings (union merge); `enabledMcpServers[]` turns on built-ins that ship disabled. `/mcp disable <name>` is session-only | Project config takes precedence over user config on a name clash. Workspace servers load only after the folder is trusted |
| **plugin** | yes, both scopes | `enabledPlugins` in `.github/copilot/settings.json` (a plugin enabled only here is scoped to that repo and stays disabled elsewhere) | `enabledPlugins` in `~/.copilot/settings.json`; files at `~/.copilot/installed-plugins/<marketplace>/<plugin>/` and `~/.copilot/installed-plugins/_direct/<source-id>/` | `plugin.json`: required `name` (kebab-case, ≤64 chars); optional `$schema`, `description`, `version`, `author`, `homepage`, `repository`, `license`, `keywords`, `category`, `tags`, and component paths `agents`, `skills`, `commands`, `hooks`, `extensions`, `mcpServers`, `lspServers` | `enabledPlugins: {"<plugin>@<marketplace>": true\|false}` — a clean boolean flip. Marketplaces registered via `extraKnownMarketplaces`; `copilot-plugins` and `awesome-copilot` are registered by default | `copilot plugin install\|list\|update\|uninstall`, `copilot plugin marketplace add\|remove\|list\|browse` |
| **context / instructions** | yes, both scopes | `.github/copilot-instructions.md`; `.github/instructions/*.instructions.md` with required `applyTo` glob frontmatter and optional `excludeAgent` (`code-review`\|`cloud-agent`); `AGENTS.md` anywhere in the tree, nearest wins; `CLAUDE.md` / `GEMINI.md` at repo root only, one each | `~/.copilot/copilot-instructions.md`, `~/.copilot/instructions/*.instructions.md` | Markdown | Delete or rename only | Repository-wide: github.com, VS Code, Visual Studio, JetBrains, Xcode, Eclipse. Path-specific: github.com and cloud agent / code review (not the IDE as documented). kendex has no ItemKind for this |
| **CLI extension** | experimental — recommend unsupported | `.github/extensions/<name>/extension.mjs` | `~/.copilot/extensions/<name>/extension.mjs` | Node module using the SDK shipped with the CLI; adds tools and slash commands | Requires `--experimental` or `/experimental on` | Distinct from plugins. Explicitly labelled experimental and subject to change |

Sources: [CLI configuration directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference) · [custom agents configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration) · [custom agents for the CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-custom-agents-for-cli) · [custom agents for the cloud agent](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/create-custom-agents) · [agent skills for the CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills) · [hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference) · [MCP servers for the CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers) · [CLI plugin reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference) · [finding and installing plugins](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/plugins-finding-installing) · [repository instructions](https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions) · [response customization](https://docs.github.com/en/copilot/concepts/response-customization) · [CLI extensions](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-cli-extensions) · [VS Code custom agents](https://code.visualstudio.com/docs/agent-customization/custom-agents).

### Settings precedence (matters for apply)

Later wins:

```
built-in defaults
  → MDM managed settings
    → ~/.copilot/settings.json
      → .github/copilot/settings.json
        → .github/copilot/settings.local.json
          → environment variables
            → command-line flags
```

Only a fixed allowlist of keys is honored at repository scope — everything else in a repo settings file is silently ignored. The repo-overridable keys are `companyAnnouncements`, `contextTier`, `deniedUrls`, `disableAllHooks`, `disabledMcpServers`, `disabledSkills`, `effortLevel`, `enabledPlugins`, `extraKnownMarketplaces`, `hooks`, `includeCoAuthoredBy`, `mergeStrategy`, `model`, `respectGitignore`. Several merge as a union (repo can add, never remove) or tighten-only, so a kendex "disable" at project scope is expressible but a project-scope "enable" over a user-scope disable is not. ([CLI configuration directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference))

**Copilot CLI also reads `.claude/settings.json` and `.claude/settings.local.json`** for a shared cross-tool subset: `companyAnnouncements`, `disableAllHooks`, `enabledPlugins`, `extraKnownMarketplaces`, `hooks`. This is load-bearing for kendex — see risk R6.

---

## 3. Detection roots

Read-only scanning needs markers that are cheap and do not produce false positives. `.github/` on its own is worthless as a Copilot marker; almost every repository has one.

### Gemini CLI

| Scope | Marker | Strength |
|---|---|---|
| Global | `~/.gemini/` directory exists | weak — Antigravity's root (`~/.gemini/config`) and the shared Google auth files create it too |
| Global | `~/.gemini/settings.json` | strong — the marker kendex uses |
| Project | `.gemini/` directory | strong |
| Project | `GEMINI.md` at repo root | strong |
| Project | `.gemini/settings.json`, `.gemini/commands/`, `.gemini/agents/`, `.gemini/skills/` | strong, per-kind |
| Ambiguous | `.agents/skills/` | weak — a cross-tool convention Copilot also reads; never treat as a Gemini-only marker |
| Not a marker | `gemini-extension.json` | this marks a repo that *publishes* an extension, not one that *uses* Gemini CLI |

Global root should be `~/.gemini` with no documented env override for the directory itself (only the two system-scope paths are overridable).

### Copilot

| Scope | Marker | Strength |
|---|---|---|
| Global | `$COPILOT_HOME` if set, else `~/.copilot/` directory | strong — **must honor the env var**, it relocates the whole root |
| Global | `~/.copilot/settings.json`, `~/.copilot/config.json` | strong |
| Project | `.github/copilot-instructions.md` | strong |
| Project | `.github/agents/`, `.github/skills/`, `.github/hooks/`, `.github/prompts/`, `.github/instructions/` | strong, per-kind |
| Project | `.github/copilot/settings.json` or `.github/copilot/settings.local.json` | strong |
| Project | `.github/mcp.json` | strong |
| Ambiguous | `.mcp.json` at repo root | shared with Claude Code — evidence of MCP, not of Copilot |
| Ambiguous | `.claude/skills/`, `.claude/agents/`, `.claude/settings.json` | Copilot genuinely reads these, but they are Claude markers first |
| Not a marker | `.github/` alone | present in nearly every repository |
| Not a marker | `.copilot/` in a repository | undocumented; see discrepancy D9 |

---

## 4. Model naming

### Gemini CLI

Accepted in an agent's `model:` frontmatter, the `--model` flag, and the `/model` picker:

| Value | Notes |
|---|---|
| `gemini-3-pro-preview` | current top tier, preview-labelled |
| `gemini-3-flash-preview` | current fast tier; used in the official subagent example |
| `gemini-2.5-pro` | previous GA top tier |
| `gemini-2.5-flash` | previous GA fast tier |
| `inherit` | agent frontmatter only — use the parent session's model |
| Auto (Gemini 3) / Auto (Gemini 2.5) | picker-only routing modes, not literal strings |

([model docs](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/model.md) and [subagents](https://github.com/google-gemini/gemini-cli/blob/main/docs/core/subagents.md))

Suggested kendex tier mapping: top → `gemini-3-pro-preview`, fast → `gemini-3-flash-preview`, inherit → `inherit`. Do **not** hardcode 2.5 as wshobson does; and prefer `inherit` wherever a tier is unspecified, since the 3.x IDs carry a `-preview` suffix that will churn.

### Copilot CLI

Documented values for `--model` / `COPILOT_MODEL` / the `model` settings key:

| Value | Documented role |
|---|---|
| `claude-sonnet-4.6` | general-purpose coding — **the CLI default** |
| `gpt-5.4` | complex reasoning |
| `claude-haiku-4.5` | fast, lightweight |
| `gpt-5.3-codex` | code-focused |
| `gemini-3.1-pro-preview` | Gemini reasoning |
| `gemini-3.5-flash`, `gemini-3.6-flash` | fast Gemini |
| `mai-code-1-flash` | fast adaptive coding |
| `auto` | let Copilot choose |

([CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference))

The platform-wide catalog is much larger — Claude Fable 5, Claude Opus 5, Claude Sonnet 5, Claude Opus 4.7/4.8, GPT-5.5, GPT-5.6 Luna/Sol/Terra, Kimi K3, Grok 4.5, and others ([supported models](https://docs.github.com/en/copilot/reference/ai-models/supported-models)) — but the CLI's own `--model` table does not list them, and availability is plan- and policy-dependent. A repository can further restrict IDs with a glob allowlist at `.github/allowed_models.txt` (the official example uses `gpt-5.2`, `gpt-5.4`, `claude-sonnet-*` and a required `fallback:` line).

**Recommendation:** do not ship a hardcoded Copilot tier map. Emit `auto` when no tier is given, pass an explicit user-set string through unchanged, and surface the model as free text rather than a validated enum. Copilot's model list moves monthly and is gated by subscription, org policy, and `allowed_models.txt`.

---

## 5. Discrepancy log — wshobson vs. official docs

"wshobson" refers to `tools/adapters/{gemini,copilot}.py`, `tools/adapters/capabilities.py`, and the harnesses doc of the wshobson repository at commit `c4b82b0`.

| # | wshobson claims | Reality | Who's right | Official source |
|---|---|---|---|---|
| D1 | Gemini has **no lifecycle hooks** (`hooks=False`; harnesses.md prints "—") | Gemini CLI has a full hook system: 11 events, regex matchers, per-hook timeouts, configured in the `hooks` key of settings.json at either scope, plus `hooks/hooks.json` inside extensions | **Official** | [hooks reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md) |
| D2 | Gemini models map to `gemini-2.5-pro` / `gemini-2.5-flash`, with a code comment asserting "GA models remain gemini-2.5-*" | The `/model` picker and the official subagent example use `gemini-3-pro-preview` and `gemini-3-flash-preview`; Auto routing has a Gemini 3 mode. `inherit` is also a valid frontmatter value and wshobson drops it | **Official** | [model docs](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/model.md), [subagents](https://github.com/google-gemini/gemini-cli/blob/main/docs/core/subagents.md) |
| D3 | Gemini tool-name map: `Grep→search`, `Glob→list_files`, `Edit→edit_file`, `WebFetch→fetch_url`, `WebSearch→google_search`, `TodoWrite→todo` | Real identifiers are `grep_search`, `glob`, `replace`, `web_fetch`, `google_web_search`, `write_todos`. Only `Read→read_file` and `Bash→run_shell_command` are correct — **6 of 8 mappings are wrong**, so any generated `tools:` allowlist silently drops those tools | **Official** | [tools reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/tools.md) |
| D4 | Gemini subagent frontmatter is `name`, `description`, `model`, `tools` | Also `kind` (`local`\|`remote`), `mcpServers`, `temperature`, `max_turns`, `timeout_mins`. Only `name` and `description` are required | **Official** (wshobson is incomplete, not wrong) | [subagents](https://github.com/google-gemini/gemini-cli/blob/main/docs/core/subagents.md) |
| D5 | Gemini item paths are `skills/`, `agents/`, `commands/` at the extension root | Correct **for an extension**, but those are not the scan roots for a user or project install. Those are `~/.gemini/{agents,skills,commands}` and `<project>/.gemini/{agents,skills,commands}` — paths wshobson never writes | Both, for different things | [extensions reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/extensions/reference.md), [skills](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/skills.md) |
| D6 | Gemini has no plugin/marketplace concept beyond "direct URL install" | Directionally right (no `marketplace.json` equivalent), but it misses the managed surface that matters to kendex: `~/.gemini/extensions/extension-enablement.json` with path-scoped enable/disable rules, `extensions.disabled[]` in settings, and `gemini extensions enable\|disable\|uninstall --scope` | **Official** on the enablement surface | [extensions reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/extensions/reference.md) |
| D7 | Copilot agents go to `.copilot/agents/<x>.agent.md` and skills to `.copilot/skills/`, described in harnesses.md as "repo level" | There is no documented repo-level `.copilot/` directory. Repository paths are `.github/agents/` and `.github/skills/`; `~/.copilot/` is the **user config root**. wshobson's `make install-copilot` symlinks `.copilot/ → ~/.copilot/`, so the *personal* scope happens to land correctly — the repo-level claim does not | **Official** | [CLI config directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference), [custom agents for the CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-custom-agents-for-cli) |
| D8 | Copilot commands are emitted to `.copilot/commands/<plugin>/<x>.md` ("legacy … for backward compat") | No such surface exists in any Copilot product. Prompt files are `.github/prompts/*.prompt.md` and are IDE-only. wshobson's own `capabilities.py` already sets `commands_native=False`, so the adapter contradicts its own capability table and writes dead files | **Official** | [response customization](https://docs.github.com/en/copilot/concepts/response-customization) |
| D9 | Copilot has **no hooks** (`hooks=False`) | Copilot has hooks at six load points — `.github/hooks/*.json`, `~/.copilot/hooks/`, the `hooks` key in repo and user settings, `.claude/settings.json`, plugin `hooks.json`, and machine policy files — with 14 events and three entry types (`command`, `http`, `prompt`) | **Official** | [hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference) |
| D10 | Copilot has **no plugin marketplace** (`plugin_marketplace=False`) | Copilot CLI ships two marketplaces registered by default (`copilot-plugins`, `awesome-copilot`), a `plugin.json` manifest, `copilot plugin install/list/update/uninstall`, `copilot plugin marketplace add/remove/list/browse`, declarative `enabledPlugins`, and custom registries via `extraKnownMarketplaces` | **Official** | [CLI plugin reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference), [finding and installing plugins](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/plugins-finding-installing) |
| D11 | Copilot has **no parallel subagents** (`parallel_agents=False`) | `subagents.maxConcurrency` (capped at 32) and `subagents.maxDepth` (capped at 256) are real settings, and the CLI ships built-in parallel subagents including `explore`, `task`, `code-review`, `general-purpose`, `research`, `security-review` | **Official** | [CLI config directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference) |
| D12 | Copilot model aliases map to `claude-fable-5`, `claude-opus-4.8`, `claude-sonnet-5`, `claude-haiku-4.5` | Those names exist in the platform catalog, but the CLI's documented `--model` table lists `claude-sonnet-4.6` (default), `gpt-5.4`, `claude-haiku-4.5`, `gpt-5.3-codex`, three Gemini IDs, and `mai-code-1-flash`. Only `claude-haiku-4.5` overlaps. Availability is further gated by plan, org policy, and `.github/allowed_models.txt` | **Official**, with the caveat that neither list is authoritative for a given user | [CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference), [supported models](https://docs.github.com/en/copilot/reference/ai-models/supported-models) |
| D13 | Copilot skills carry `user-invocable: true` and `disable-model-invocation: true` frontmatter | Those two fields are documented for **agents**, not skills. The CLI skills reference lists `name`, `description`, `license`, `allowed-tools` only. Unverified on SKILL.md — treat as not supported | **Official** | [agent skills for the CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills), [custom agents configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration) |
| D14 | Copilot's context file is `AGENTS.md` | Partly right. `AGENTS.md` is honored and nests (nearest wins), but `.github/copilot-instructions.md` is the primary repository instruction file, `.github/instructions/*.instructions.md` adds path-scoped rules, and `CLAUDE.md`/`GEMINI.md` are root-only single-file fallbacks | **Official** | [repository instructions](https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions) |
| D15 | (Not wshobson) GitHub's own docs contradict themselves on custom-agent precedence | The CLI config-directory reference says project-level `.github/agents/` wins over personal `~/.copilot/agents/`; the create-custom-agents-for-CLI page says the home-directory copy is used instead. | **Unresolved** — do not encode a precedence rule; report both as observed installations | [CLI config directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference) vs. [custom agents for the CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-custom-agents-for-cli) |

One item where wshobson is right and worth keeping: Gemini's `@{path}` file-injection syntax in command prompts is real and is the correct way to pull a large body into a TOML command ([custom commands](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/custom-commands.md)).

---

## 6. Risk notes

**R1 — Gemini extensions are global-only with path-scoped enablement.** Installation always lands in `~/.gemini/extensions/<name>/`, but enablement is a rule file (`extension-enablement.json`) whose entries are path globs with `!` for disable and a trailing `*` for "include subdirectories", with conflict and child-of-parent resolution in code. Hand-editing this is easy to get wrong and there is no schema doc. *Recommendation: observe global only; no install, no remove. Toggle only if it shells out to `gemini extensions enable|disable --scope`, otherwise leave toggle off too.*

**R2 — Gemini's system settings layer outranks project settings.** On a managed machine, a project-scope value kendex writes can be inert. This does not block anything, but Audit must not report drift as "applied" when an override is winning. *Recommendation: scan the system paths read-only and flag the conflict rather than silently disagreeing with reality.*

**R3 — Gemini subagents sit behind `experimental.enableAgents`.** The kind is documented and stable-looking, but a feature flag can flip. `kind: remote` subagents additionally reference off-machine execution. *Recommendation: manage `kind: local` agents; treat `kind: remote` as observe-only.*

**R4 — Copilot's `COPILOT_HOME` relocates the entire global root.** Hardcoding `~/.copilot` will scan the wrong place for anyone using the env var (plus the legacy `--config-dir` flag). *Recommendation: resolve the root through `Env` the way the Claude adapter resolves `home`, with the env var checked first.*

**R5 — Copilot hooks are all-or-nothing.** The only documented switch is `disableAllHooks`. There is no per-hook enable flag, so kendex's non-destructive toggle (invariant 5) must be a file rename for `.github/hooks/*.json` and `~/.copilot/hooks/*.json`, and must be unavailable for hooks declared inline in a settings `hooks` key — the structured-edit path there would have to remove and restore the entry, which is a lossy toggle. *Recommendation: manage file-backed hooks; observe inline settings hooks without offering toggle.*

**R6 — Copilot reads Claude Code's files. This is the biggest modelling problem.** Copilot CLI discovers skills from `.claude/skills` and `.agents/skills`, VS Code discovers agents from `.claude/agents`, and the CLI reads `.claude/settings.json` and `.claude/settings.local.json` for `enabledPlugins`, `extraKnownMarketplaces`, `hooks`, `disableAllHooks`, and `companyAnnouncements`. Gemini symmetrically reads `.agents/skills`. Two consequences for kendex:

  1. One file on disk is simultaneously an installation for two harnesses. `Installation = item × harness × scope` will double-count unless the adapter deliberately does *not* claim the shared directories.
  2. A write kendex makes to Claude's `settings.json` now changes Copilot's behavior. Invariant 2 (never clobber a user-set value) already covers the mechanics, but the *blast radius* is wider than the Claude adapter assumes.

  *Recommendation for v0.2: each adapter claims only its own namespace — Copilot claims `.github/**` and `~/.copilot/**`, Gemini claims `.gemini/**` and `~/.gemini/**`. Leave `.agents/` and `.claude/` to the Claude adapter, and note the cross-read in the UI rather than modelling it as a second installation.*

**R7 — Copilot repository settings are an allowlist with directional merges.** Only 14 keys are honored at repo scope and several merge as union (repo can add, never remove) or tighten-only. A project-scope "enable" that contradicts a user-scope "disable" is not expressible. *Recommendation: at project scope offer disable but not enable for `disabledSkills` and `disabledMcpServers`; the capability table should carry this as a scope asymmetry, not a silent no-op.*

**R8 — Preview and IDE-only surfaces to leave out of v0.2 entirely.** Prompt files (`.github/prompts/*.prompt.md`, public preview, IDE-only); chat modes (`.chatmode.md`, renamed to custom agents — old files require a manual rename, they do not auto-load); Copilot CLI extensions (`.github/extensions/`, `~/.copilot/extensions/`, explicitly experimental, needs `--experimental`); Gemini's task-tracker tools. None should appear in the capability table as supported.

**R9 — Both tools' config formats have migrated recently.** Gemini's settings.json moved to a nested v2 schema with automatic migration; Copilot moved user-editable settings out of `config.json` into `settings.json` and migrates XDG-based paths into `~/.copilot` at startup. Machines that have not launched the newer CLI still hold the old shape. *Recommendation: the scanner should tolerate both shapes on read and only ever write the current one.*

---

## 7. Recommended v0.2 capability table entries

Derived from the matrices above. `managed` / `observe_only` / `unsupported` match the constructors in `crates/core/src/harness/caps.rs`; the scope constants are `BOTH`, `PROJECT`, `GLOBAL`, `NONE`.

| Harness × kind | Recommendation | Why |
|---|---|---|
| Gemini × Agent | `managed(BOTH)` | symmetric file dirs, well-documented frontmatter |
| Gemini × Skill | `managed(BOTH)` | subdir-per-item with `SKILL.md`, same shape as Claude |
| Gemini × Command | `managed(BOTH)` | file dir with `:` namespacing; only `.toml` loads, so rename-toggle is safe |
| Gemini × Hook | `managed(BOTH)` | structured edit of the `hooks` key, same reader shape as Claude's `HooksObject` |
| Gemini × McpServer | `managed(BOTH)` | structured edit of `mcpServers`; note the toggle file is global-only |
| Gemini × Plugin | `observe_only(GLOBAL)` | global-only install plus an undocumented path-rule enablement file (R1) |
| Gemini × PiExtension | `unsupported()` | not a Gemini concept |
| Copilot × Agent | `managed(BOTH)` | `.github/agents/` and `~/.copilot/agents/`, plain files |
| Copilot × Skill | `managed(BOTH)` | `.github/skills/` and `~/.copilot/skills/`; disable via `disabledSkills` (project scope is disable-only, R7) |
| Copilot × Command | `unsupported()` | no file-backed slash-command kind exists (D8) |
| Copilot × Hook | `managed(BOTH)` for file-backed `.github/hooks/*.json` and `~/.copilot/hooks/*.json`; observe the inline settings `hooks` key | rename-toggle works on files, not on inline entries (R5) |
| Copilot × McpServer | `managed(BOTH)` | `.mcp.json` / `.github/mcp.json` / `~/.copilot/mcp-config.json`, standard `mcpServers` shape |
| Copilot × Plugin | `observe` + `toggle` at `BOTH`, install/remove parked | `enabledPlugins` is a clean boolean flip, but install needs marketplace resolution — park it with the Claude marketplace work |
| Copilot × PiExtension | `unsupported()` | not a Copilot concept |

Two new `Reader` variants are needed beyond what exists today: one for Copilot's hook-file JSON (`{version, disableAllHooks, hooks}` — different enough from `HooksObject` that reusing it would be a lie), and one for the `enabledPlugins` map in Copilot's settings files. Gemini's `mcpServers` and `hooks` both fit existing readers (`McpServersJson` needs only to accept the key nested inside settings.json rather than at the root of a dedicated file).
