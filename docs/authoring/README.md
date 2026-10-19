# Authoring a marketplace

A kendex marketplace is a git repository of harness packages. `kendex marketplace subscribe owner/repo` discovers existing skills. The structure below adds catalog metadata and other package kinds.

## Start

```sh
kendex marketplace new my-marketplace
```

That creates a folder holding a `kendex.toml`, a README and the check workflow, initialised as a git repository. `--license mit|apache-2.0` adds the licence that submission needs. Templates for each file are in [templates/](templates/); `kendex init --kind agent|skill|hook <name>` scaffolds one item.

## Layout

```
my-marketplace/
  kendex.toml                                  what this marketplace says about itself
  agents/<name>.md                             one agent per file
  skills/<name>/SKILL.md                       one folder per skill; the folder name is its name
  skills/<name>/kendex.settings.toml.example   the settings that skill declares
  hooks/<name>.sh   commands/<name>.md   mcp/<name>.toml   pi-extensions/<name>/
  output-styles/<name>.md                      one response style per file
  README.md                                    how to subscribe
  LICENSE
  .github/workflows/kendex-check.yml           the check, on every push
```

- A skill's identity is its directory name; a `SKILL.md` whose `name:` disagrees with its folder is a check finding.
- Executable kinds are never guessed: hooks, commands and MCP servers install only from a repository that declares kendex's layout (any parseable `kendex.toml` does) or from a plugin registry. A `hooks/` folder in an undeclared repository is repository tooling, not installable content.

A `.claude-plugin/marketplace.json` registry can place a plugin at `.` or `./`, the repository root, or at a nested local directory. An entry's `skills` can name one skill folder or list folders as strings or objects with a string `path`. Each folder must hold its own `SKILL.md`. These paths are relative to the plugin's source directory. Absolute paths, parent components (`..`) and symlinks are refused.

A declared `skills` list selects only those folders. An empty list selects none. Without `skills`, kendex reads the plugin's `skills/<name>/SKILL.md` layout. Each skill installs under `<plugin>/<folder-name>`; object `name` and `invoke` fields do not replace that identity. Select it with `kendex add OWNER/REPO --skill PLUGIN/FOLDER`.

## kendex.toml

```toml
[marketplace]
name = "my-marketplace"
description = "Skills for the whole team"
author = "Jane Doe"
license = "MIT"            # an SPDX id; omit while undecided
homepage = "https://example.com"
tags = ["rust", "review"]

# Optional: where agents and skills live.
[catalog]
skills = ["skills", "extra-skills"]
agents = ["agents"]

# Optional: curated sets installed under one name. Members are bare names,
# one list per kind: agents, skills, commands, hooks, mcp-servers.
[bundles.starter]
description = "Everything a new project needs"
skills = ["review"]
agents = ["scout"]

# Optional: items the catalog no longer ships, one table per kind (skills,
# agents, hooks, commands, mcp-servers, output-styles, pi-extensions), and
# sets under bundles, each name with a one-line migration, or "" for none.
[retired.hooks]
old-check = "declare new-check"

# Optional: what an agent's `role:` implies, per harness (claude, pi) and role.
[role-policy.pi.engineer]
deny-tools = ["question"]
allowed-subagents = ["scout"]
```

A consumer still declaring a retired item refreshes with one notice keyed by its name that carries its migration, and the item stays installed as it is; one never installed is not installed. A retired bundle refreshes the same way, its notice keyed `bundle <name>` and its installed members and what they require kept; `kendex refresh --prune` drops its declaration and removes the members nothing else needs. A declared bundle the catalog neither offers nor retires fails the refresh, and its installed members stay. `kendex refresh --prune` removes a retired item, its declaration, and any workflow adopted from its templates that still holds the template's bytes; a copy you edited, the item's or such a workflow, stays, and verify keeps failing it. Under the prune the keyed line names the catalog, says what this prune does with the item, and ends with the migration. An armed hook that requires a retired item is withheld on each tool it requires that item on, with a warning naming the item and carrying its migration where the catalog gives one: every tool the hook runs on for a skill in `requires-skills`, and for a hook in `requires`, the tools its `requires-on` line names, or every tool it runs on without one. This holds whether the retired item is kept or pruned. The withheld hook's installed copy goes as a leftover does. A copy you edited stays as an edit conflict and keeps the retired item it requires installed with it, under `kendex refresh --prune` too; once the retired item goes, by `kendex remove` or because it was never installed, every hook that requires it, directly or through another hook, goes with it, edited or not. Removing either hook of such a pair by name takes the other. A kept retired item stays installed until `kendex refresh --prune` even where every hook requiring it is withheld, except a retired hook whose installed copy requires a withheld hook: it is withheld with that hook, so neither runs alone. For a declared hook left uninstalled this way, `kendex verify` names the withholding and its fix. Any other item that requires a retired item installs, with that warning. A catalog that retires an item drops it, in the same change, from every list that requires it: a skill's `dependencies`, and a hook's `requires` and `requires-skills`.

`[role-policy.<harness>.<role>]` sets the tool restrictions and delegation targets for an agent's `role:` (`engineer`, `reviewer`, `planner`, `analyst`, `manager`). `deny-tools` uses the harness's own tool names. Pi's `allowed-subagents` sets the delegation targets unless a per-agent override replaces them. Declaring `[role-policy]` replaces the defaults for every supported harness and role. An omitted harness, an omitted role, and an agent with no role get no role restrictions or delegation targets. Claude Code subagents cannot start subagents, so `Agent` stays denied there. A nonempty `allowed-subagents` list under `claude` is refused. An invalid policy makes the whole catalog a check finding.

A catalog with no `[role-policy]` declaration keeps the current defaults. Claude Code denies `AskUserQuestion` to every agent except a planner. Pi denies `question` to every agent except a planner and denies `tasks_write` to reviewers. Pi engineers may delegate to `scout` when it is enabled and installed for Pi; other roles have no default delegation targets. These defaults also apply to an agent with no role, with no delegation targets. [Per-agent overrides](#agent-permissions) can replace the role restrictions and Pi delegation targets.

Without a `[marketplace]` table the directory listing falls back to what GitHub knows. A `kendex.toml` that exists but does not parse makes the whole catalog a finding, never a silently different catalog.

## What each kind needs

- Skill: `skills/<name>/SKILL.md`, or a declared plugin skill folder, with frontmatter `name` (matching the folder) and `description`; extra files in the folder ship with it.
- Agent: `agents/<name>.md` with frontmatter `name` and `description`; optional `model`, `color`, tool allow and deny lists, and `tracked-outputs`, file paths it commits (`reports/<slug>.md`); `kendex verify` warns when an installing project ignores one.
- Hook: `hooks/<name>.sh` with a comment header naming `event`, an optional `matcher`, and a `description`.
- Command: `commands/<name>.md` with frontmatter `description`.
- MCP server: `mcp/<name>.toml` describing the invocation.
- Output style: `output-styles/<name>.md`; [frontmatter and declarations](output-styles.md).

A description is never guessed: an empty one stays empty and is a check finding. Tags come from `tags = [...]` in `[marketplace]` or per item in frontmatter, never inferred from names. A marketplace page renders the package's own body, the `SKILL.md` for a skill and the one file for every other kind; a `README.md` beside a skill ships with it and is listed, not rendered.

## Skill dependencies

`dependencies.required` in `SKILL.md` frontmatter names skills from the same catalog. `dependencies.optional` names skills installed only when a person selects them with `--with`. `dependencies.agents` names required agents from the catalog's `agents/` directory. Each agent uses the same render as `add --agent` for the selected harnesses that support agents at the install scope, and brings the skills this catalog assigns to it ([Agent skills](#agent-skills)). A consumer `[agent-skills]` row for the agent replaces that assignment: the agent brings the row's skills this catalog offers, and a row skill from another catalog warns until it is installed. An assignment never chooses a skill's revision or prevents its installation. A skill brought only by assignments follows its source. An assigned skill the scope already holds, declared or brought in by another item, keeps its own declaration and revision. kendex switches on a held skill that another item brought in switched off, while the agent is on. A skill you declared off stays off. An assigned skill that does not install is never a missing-dependency finding, and the agent's warning covers one the scope has no declaration for ([Agent skills](#agent-skills)). A harness that cannot install the agent gets a warning on the skill. The skill still installs there. Agents have no optional dependency list. Skills cannot declare hook dependencies.

```yaml
dependencies:
  required: [shared-skill]
  optional: [extra-skill]
  agents: [helper]
  commands:
    - command: agent-browser
      purpose: Browser automation
      floor: "0.1.0"
      packages:
        npm: agent-browser
    - command: op
      purpose: Read credentials from 1Password
      optional: true
      packages:
        brew: 1password-cli
```

Refresh reads the dependency lists again. A removed skill's dependencies leave with `remove --sweep` when no other item needs them. An agent also added by name stays. Derived dependencies do not become explicit choices in the consumer manifest. A skill with no `agents` list keeps its existing behavior. Older kendex builds ignore that key.

A required skill or agent the catalog does not offer produces a warning with its name and a remedy. The parent skill still installs.

`dependencies.commands` lists external commands the skill uses. Each row needs a `command` name found on PATH and a `purpose`. `optional` defaults to `false`. `packages` maps package manager names to package names. kendex reports these names and installs no system tools. An invalid row refuses the skill and names its row and field.

Install and `kendex check` report a missing required command as a finding. A missing optional command is a notice. The skill still installs. Check reads the installed declaration and the current PATH. Disabled skills produce no command findings.

`floor` is an optional minimum version. Use a numeric dotted version. Omitted components compare as zero. Additional components compare numerically, including browser versions. Pre-release and build suffixes follow semantic version rules. kendex asks the resolved command for `--version` only when a floor is declared. It reads a dotted version from the first non-empty output line. A readable version below the floor is a finding for a required command and a notice for an optional command. An unavailable or unreadable version is always a notice. Bash release banners with a parenthesized build number are unreadable. Notices leave the check exit status unchanged.

## Agent skills

Declare an agent's required skills once in the catalog manifest. Use one row per agent in `[agent-skills]`. Use `[role-skills]` to add skills for agents with the named `role:`.

```toml
[agent-skills]
scout = ["recon"]
rust = ["dev", "code-quality"]

[role-skills]
reviewer = ["dev"]
```

An agent with no row of its own can match skills by name prefix. For example, `rust` matches `rust` and `rust-perf`. An explicit catalog row replaces those prefix matches. Role skills are added to either list. A `reviewer-` agent with no exact row reads its base agent's row: `reviewer-rust` reads `rust`.

The consumer can replace an assignment in its own `[agent-skills]` table. Skills removed there stay removed. Refresh adds skills that the catalog newly assigns since the recorded installation. Skill names in a consumer assignment can come from another subscribed catalog.

Claude Code receives `skills:` frontmatter for preload. Cursor installs the agent as a rule and omits the skill list. The other harnesses receive a `## Required Skills` section with paths to the skills.

Adding an agent normally installs its available assigned skills. A bundle or `--no-auto-skills` can leave them out. An agent that a skill requires brings its assigned skills even when it is declared with `--no-auto-skills` or comes from a bundle; the consumer `[agent-skills]` row changes them. Assignments follow the [skill dependency revision rule](#skill-dependencies): they never choose a skill's revision or prevent its installation. Install and apply warn once per agent and missing skill when the scope has no install declaration for it. A skill installed through a bundle or dependency satisfies the assignment. Install the skill, or remove it from the agent's `[agent-skills]` row. An unresolved consumer assignment warns and the agent still renders with its available skills. A recorded fork with an unavailable skill refuses the operation.

## Agent models

An agent requests a portable model class through its `model:` field. Consumer settings select models for that class at run time or in a native agent file. These settings belong in the personal or project manifest, not the catalog manifest. Project values replace personal values per class, and bindings replace them per harness and class.

```toml
schema = 7

[model-classes]
standard = "openai/gpt-6.1-sol"

[model-bindings.codex]
standard = "gpt-6.1-sol"

[model-bindings.copilot]
standard = "claude-opus-4.6"
```

`model-classes.<class>` supplies a provider-qualified selector to runtime class resolution through `kendex tier-model`. It does not put that selector in a static agent file. `[model-bindings.<harness>]` selects a native model for a class in a Codex or Copilot agent file. Other harnesses reject bindings. Claude Code already renders the class family alias. Pi keeps the class for runtime dispatch.

Bindings require manifest format 7. Upgrade kendex before adding bindings. kendex reads a schema 6 personal or project manifest in the current form and persists `schema = 7` on apply, refresh, install or the next write. It keeps comments and layout. Read-only commands and plan preview leave the file unchanged. An unsupported older schema or a newer schema still refuses without changing the file.

Bindings use canonical class names and nonempty selectors with no whitespace. The model owner, `crates/core/src/harness/models.rs`, declares the classes. Render preview checks the selector against the harness loader. A binding gives no compatibility warning. Without a binding, the agent keeps its existing render. `inherit` keeps the session model. A per-agent `[agent-frontmatter.<harness>.<agent>] model` replaces the request before binding selection, so it takes precedence.

On Copilot a bound model outranks the launch model. Bind a class when its agents must use that model even if the session uses another. Bindings change no runtime `model-classes` selection.

## Agent permissions

`[agent-frontmatter.<harness>.<agent>]` sets per-agent overrides in the catalog or consumer manifest. Consumer values replace catalog values per field. `deny-tools` combines both lists and adds restrictions to the agent's own tool permissions.

- `role-deny-tools` replaces the role's tool restrictions for Claude Code or Pi. An explicit `[]` removes all role restrictions. It does not remove restrictions from `deny-tools`, the source agent, or the harness itself.
- Pi's `allowed-subagents` replaces the role's delegation targets. An explicit `[]` turns delegation off. A nonempty list does not cancel an explicit deny of `delegate_subagent`.

```toml
[agent-frontmatter.pi.my-agent]
role-deny-tools = []
deny-tools = ["bash"]
allowed-subagents = []
```

This agent has no role tool restrictions or delegation targets. It still loses `bash` and the [Pi orchestration tools](../adapters/pi.md#format).

Forking an agent, including a fork beside the original, or keeping it when detaching its source carries its catalog settings into the consumer manifest. A declared role policy travels as per-agent `role-deny-tools` for Claude Code and Pi, plus Pi `allowed-subagents`. Empty lists travel too, so the local agent does not regain the defaults. Existing per-agent replacements take precedence over the role policy. Additional `deny-tools` restrictions stay separate and still apply. The fields are manifest settings; `role-deny-tools` is not a native agent frontmatter key. The renderer writes the resulting restrictions into each harness's native agent file.

## What a person reads

Every surface that names a package — a marketplace row, its page, a My Library row, the preview on that row's name, and both searches — shows one line: the package's `summary`, or its `description` where no summary is written.

Write the summary where the kind already keeps its metadata; kendex reads no second file.

| Kind | Where the summary goes |
|---|---|
| Skill | `summary:` in `SKILL.md` frontmatter |
| Agent | `summary:` in the agent file's frontmatter |
| Command | `summary:` in the command file's frontmatter |
| Output style | `summary:` in the style file's frontmatter |
| Hook | `# summary:` in the `# ---` comment header |
| MCP server | `summary = "…"` in `mcp/<name>.toml` |
| Pi extension | `description` in its `package.json` |

```sh
# ---
# name: block-bare-cd
# event: PreToolUse
# description: Refuse a command with a line that is only a `cd`.
# summary: Stops a command whose whole line is a `cd`. Where the shell stays open between tool calls, that moves every later command with it.
# ---
```

`description` and `summary` are not the same job. A `description` is what an agent reads to decide whether to load the package, so it is written for the agent; a `summary` is what a person reads to decide whether they want it. Where a package writes only a description, that description is shown.

Write a summary as one or two short sentences about what the package does and what it changes for the person using it. Leave the precise rules, flags and limits to the package's own documentation. A long summary is not refused: a row clamps it to two lines.

A package that writes neither shows no line. That is a supported state: kendex never fills the gap with the command a hook runs, the URL an MCP server is reached at, the path a file sits at, or anything read out of a script. Those stay in the package's details, where someone inspecting execution looks for them.

## A consumer's own instructions

A project adds its own text to an installed skill, agent or command in its manifest, never by editing the installed copy. `[skill-instructions]` writes into a skill's `SKILL.md`, and `[command-instructions]` writes into every tool's copy of a command. `[agent-additional-instructions]` adds text to an agent's `## Additional Instructions` section:

```toml
[agent-additional-instructions]
maintainer = "Read the project's writing rules before editing documentation."

[command-instructions]
all = "Every command reads this."
code-scrub = """
Merge review: a second reviewer signs off before merge.
"""
```

A key names the package; `all` or `*` names every package of that kind. kendex renders the shared text first, then the package's own. Skills and commands get a `## Project Instructions` block between `kendex:project-instructions` markers, directly after the frontmatter and above the publisher's body. The publisher's body is never edited and still updates, so a project keeps its text without copying the command. A tool that reads a command file of its own gets the block in that file. Gemini gets it in the TOML `prompt`. Codex gets it in the generated skill. With no key for a command, every copy is the publisher's own rendering, byte for byte. In a source-catalog checkout the table goes in `kendex-local.toml`, which configures that checkout alone and ships to no install.

A paragraph several skills share, but not every skill, is written once under a name in `[shared-text]`. A `[skill-instructions]` value places it with `{{shared-text:NAME}}`, where the token stands. Each skill picks its own paragraphs and their order:

```toml
[shared-text]
delivery = "Commit on the item branch and open one pull request."

[skill-instructions]
dev = "{{shared-text:delivery}}"
orch = """
Hand each lane one issue.

{{shared-text:delivery}}
"""
```

Each skill's `SKILL.md` carries the full paragraph, because a skill is read alone; only the manifest's copy is single, so editing it changes every skill that places it. The token works in `all` and `*` too. A shared text cannot place another, and a token naming no `[shared-text]` entry is refused when the manifest loads. kendex writes the token back as written. A template saved with package customizations expands tokens in the selected packages' own `[skill-instructions]` entries. It excludes the shared `all` and `*` entries.

## Settings

Only a skill seeds settings into a project, through its `kendex.settings.toml.example`. The same file declares the credentials the skill reads, which kendex keeps out of committed configuration: [settings.md](settings.md).

For project-defined shell command restrictions, configure the [command-safety hook](command-safety.md).

## Repository effects

Almost every package is inert: installing it writes files into the tool directories and changes nothing else. A package that also changes the repository itself — a git hook, a config value, anything outside the folders kendex manages — declares that in its `SKILL.md` frontmatter, under `repo-effects`, and kendex shows the declaration and asks a separate question about it. The package's files land with the rest of the install; the effect waits for that second answer.

```yaml
repo-effects:
  summary: "One line: what this changes about the repository."
  writes:
    - ".git/hooks/kendex-guards"
  installer: "scripts/install-git-hooks"
  uninstaller: "scripts/install-git-hooks --uninstall"
  checker: "scripts/install-git-hooks --check"
  removal: "How to undo it by hand."
  notes:
    - "Anything the reader should know before saying yes."
  companions:
    - "doc-limits"
```

- `writes` are repo-relative paths, each of which stays inside the repository. A path under `.git/` maps to the repository's common git directory, which every work tree shares, and is disclosed as shared.
- `configured-by` is optional: the name of a top-level manifest table that enables the effect, such as `configured-by: bot-instructions`. A name that denotes no manifest table refuses the declaration. When the table is absent from the offered commit, kendex skips the not-set-up commit hold without running package code. It reads `kendex.toml`, or `kendex-local.toml` when that commit declares a source catalog. An empty table still enables the hold. A prior working-manifest edit left out of the commit changes neither the table check nor manifest selection. Removing a table does not remove marked bot files; the package's pre-commit check still refuses those as orphans.
- `installer` and `uninstaller` are commands relative to the package directory. kendex runs the installer when somebody says yes, and the uninstaller before any verb takes the package away.
- `checker` is optional and read-only: a command, relative to the package directory, that reports whether the effect stands here.
- `staged-checker` is optional and read-only: a command, relative to the package directory, that reports whether the package's files are current in the commit the git index holds rather than in the working tree. Declare it where a commit hook judges your files, the way `bot-instructions check --staged` does.
- A field kendex cannot read refuses the whole declaration; a script path kendex will not use is dropped and the rest stands. A key kendex has no reader for is read past and named in the disclosure: a catalog adds a field before every binary reads it.

### The checker contract

The exit status is the whole answer, and it is the same taxonomy the commit hooks use:

| Exit | Means |
|---|---|
| `0` | The effect is in force here. |
| `1` | It is not. |
| anything else | The check could not be taken. |

Where kendex recorded arming the effect, `kendex verify` fails, and `kendex refresh` names the package and exits as it otherwise would, on a `1`, on a check that could not be taken, and on a declaration that will not read. On a `1` the row names the way to apply its repository changes again (`kendex guard install` for commit-guards; the package's page in the app, or a remove and an add with `--allow-repo-effects`, for any other); on the other two it names no re-arm remedy, because the checker's own words, or the reason the declaration would not read, are the way out. Verification does not rerun an installer. After an app or CLI project update, kendex reruns the armed selected configuration owner's installer as its renderer. The [repository-effects rules](../architecture/repo-effects.md#rules) define the selection. An unarmed selected owner runs no installed package code during an apply, refresh or check, unless a run that commits passes `--allow-repo-effects`, which sets the package up where it holds the commit. `kendex bot-instructions-render`, which a consumer refresh run calls in the checkout it discards, renders the selected owner once and records nothing. Arbitrary installers do not rerun automatically because a yes applies to the disclosure of its day, and a later version may declare more. A scope with no arming record reports no result from the installed package's arming-based checker.

`kendex verify --bot-instructions-from TRUSTED_PACKAGE` licenses a trusted bot-instructions checker outside the checked project for that call. It reads the installed package's doctrine as data and compares whole bot files. A configured installed package gets a verification result even without an arming record. A failed comparison fails verification and grants no file ownership.

The script writes nothing and changes nothing. Whatever it prints on either stream reaches the person as the package's own words, so put the remedy there.

Nothing the declaration says decides when the checker runs. Your script comes out of a checkout, and a checkout arrives with a fetch, so opening a package's page must not run it. What licenses a run is kendex's own record of having armed the effect in that repository: kendex writes it when your installer exits clean, keeps it in a git directory, which git clones for nobody, and drops it when your uninstaller runs. Which one is your effect's reach: an effect under `.git/` is the whole repository's, so one arming answers for every work tree; an effect elsewhere in the checkout is the work tree it was armed in and no other. A repository nothing here armed runs none of your code.

A `staged-checker` keeps the same exit taxonomy and the same licence. kendex runs it exactly as declared, with `GIT_INDEX_FILE` naming a temporary index that holds the commit it is about to offer, before it offers a commit that carries your files; kendex adds no argument to it or to `checker`. A `0` there leaves the commit on offer whatever the working tree says. A `1` holds it: as out of date, with your setup offered, where `checker` also exits `1`, and otherwise with leaving the files as diffs as the only way on. An effect under `.git/` is never asked, since a commit carries none of its files. A package that declares no staged checker is judged by `checker` over the working tree alone.

That leaves a repository somebody armed by hand, which kendex has no record of. The person can ask for the status themselves — the package page offers it — and their asking is its own licence, so your checker still answers there.

kendex reports one of these per project, and a package that declares an effect with no checker shows a status it does not have rather than a guess:

| State | Reached by |
|---|---|
| Active | The checker exited `0`. |
| Not active | There is no arming record, so nothing ran; or somebody asked, and the checker exited `1` where kendex had no record. |
| Needs repair | kendex armed it here and the checker exited `1`. |
| Could not check | The checker exited outside the taxonomy, or would not run. |
| Status unavailable | The package declares an effect and no checker. |

## The check

```sh
kendex marketplace check
```

Validates every package the way installing validates it: names a harness's loader would refuse, skill trees that disagree with themselves, and settings templates outside the grammar fail it. So does a link in a shipped file to a skill's top-level `tests/`, `evals/` or `DEVELOPMENT.md`, which no install receives, and a link to the catalog's own GitHub source (`blob/<ref>/<path>`) whose file or `#heading` is gone; other remote links are not read. The safety rules an install runs print their findings and the package's score and fail nothing; the score is advisory wherever it is shown. The scaffolded workflow runs the check on every push and pull request.

## Publishing

Push the repository to GitHub, make it public, and submit it from the app (Mine, then Submit to community), with `kendex marketplace submit`, or at [kendex.ai/submit](https://kendex.ai/submit). kendex.ai verifies your push authority over the repository, indexes it and lists it. The listing follows the repository id, so a rename keeps it.
