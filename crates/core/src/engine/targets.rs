use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::configedit::ConfigEdit;
use crate::env::Env;
use crate::harness::{Enforcement, adapter};
use crate::model::{HarnessId, ItemKind, Scope};

/// The notice every native event adapter emits when no listener can run it.
pub(super) fn unsupported_hook_event(name: &str, event: &str, harness: HarnessId) -> String {
    format!(
        "kendex-hook-unsupported: harness={record_arg0} event={record_event} hook={record_name}\nThis harness cannot run the hook event. Nothing is installed for it.",
        record_arg0 = crate::names::shown(harness.name()),
        record_event = crate::names::shown(event),
        record_name = crate::names::shown(name),
    )
}

/// What installing a hook on this harness actually buys. A tool that only
/// reads the file must never be presented as one that acts on it: the
/// warning travels with the plan, the preview, and the audit page. Read
/// through `hook_enforcement`, so a Pi hook with no carrier registered
/// anywhere Pi loads gets its downgrade said here, per item.
pub(super) fn advisory_notice(
    env: &Env,
    scope: &Scope,
    harness: HarnessId,
    name: &str,
) -> Option<super::ItemWarning> {
    let tool = harness.display_name();
    if crate::harness::hook_enforcement(env, scope, harness) != Enforcement::Advisory {
        return None;
    }
    let (message, remediation) = match harness {
        HarnessId::Pi => (
            format!(
                "kendex-hook-carrier-missing: harness=pi hook={record_name} carrier=pi-hooks\nThe pi-hooks carrier is not registered in any settings pi loads here — the hook is written but nothing will run it",
                record_name = crate::names::shown(name),
            ),
            format!(
                "install the {} extension at either scope",
                crate::pi_ext::carrier::CARRIER
            ),
        ),
        _ => (
            format!(
                "kendex-hook-advisory: harness={record_arg0} hook={record_name}\nThis protection is advisory on {tool} — it installs as text the model may ignore, not a check the tool runs",
                record_arg0 = crate::names::shown(harness.name()),
                record_name = crate::names::shown(name),
            ),
            format!(
                "keep it for the tools that run hooks — Claude Code, Codex, Gemini CLI, GitHub Copilot, Antigravity — or accept it as guidance on {tool}"
            ),
        ),
    };
    Some(super::ItemWarning {
        kind: ItemKind::Hook,
        name: name.to_owned(),
        harness: Some(harness),
        message,
        remediation: Some(remediation),
    })
}

/// Which shape a registry file speaks. Claude, codex, cursor and Gemini all
/// take the same matcher-with-handlers object; Copilot's hook files are a
/// `{version, hooks}` document whose entries carry the command themselves;
/// Antigravity's `hooks.json` keys that same nested shape by hook name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HookFormat {
    Nested,
    Copilot,
    Antigravity,
}

/// Where one hook's artifacts live for a harness at a scope. Install and
/// removal both read this, so the command string they register and strip can
/// never disagree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum HookTarget {
    /// A shell script the harness runs, registered in a JSON hooks file.
    Script {
        path: PathBuf,
        command: String,
        registry: PathBuf,
        format: HookFormat,
        /// codex gates hooks behind `[features] hooks = true`.
        feature: Option<PathBuf>,
    },
    /// An instruction file the opencode config references — opencode has no
    /// native hook surface, so the constraint travels as prose.
    Instruction {
        path: PathBuf,
        config: PathBuf,
        reference: String,
    },
    /// A cursor advisory rule: a file, no registration.
    Rule { path: PathBuf },
}

/// How an instructions row spells the directory kendex renders opencode
/// instruction files into, at this scope. The rows hook_target writes and
/// the rows the stale-row sweep claims both read this, so the spelling
/// written and the spelling swept can never disagree.
pub(super) fn opencode_instruction_prefix(scope: &Scope) -> &'static str {
    match scope {
        Scope::Global => "instructions/",
        Scope::Project { .. } => ".opencode/instructions/",
    }
}

/// A project-scope hook command: find the script above the working
/// directory, then run it.
///
/// `rel` is the script's place under the project root, and nothing else in
/// the command names a directory, so the text is the same on every machine.
/// It has to be: a project registry is a file repositories commit, and a
/// rendered absolute path would make each clone's copy differ and churn on
/// every apply. `$(git rev-parse --show-toplevel)` was machine-independent
/// and wrong instead — kendex installs into a project that is no git
/// repository, where it substitutes nothing (`engine::posture`), and into
/// one below the git top level, where it substitutes the enclosing tree's
/// root (`guard::repo`). Claude Code needs none of this: it publishes a
/// project root in a variable.
///
/// The walk looks for the script itself, not for a project marker: the
/// harness read this registry by walking up from its working directory for
/// its own config, so the project the registration came from is an
/// ancestor, and it is the one that holds `rel`. A marker would be a proxy
/// for that, and a wrong one — a nested `.claude/` stops a marker walk
/// short, and a Copilot-only project has no marker directory at all.
///
/// The start is refused unless it is absolute: a working directory removed
/// under the session leaves `pwd` answering `.`, and a walk from there
/// never reaches `/`. When nothing from the start up holds the script, the
/// command refuses, naming the start and the file: a hook that did not run
/// must not read as one that allowed.
/// Its own output starts with `kendex-hook-missing`; a launching shell may
/// emit a startup diagnostic before it executes this registered command.
///
/// `rel` goes through [`crate::names::quoted`], never interpolated inside
/// double quotes, so a segment holding a `$` or a backtick is read as the
/// segment it is. It is assigned first, before the walk, because it is also
/// what names this hook to a reader: [`crate::hook::command_stem`] takes the
/// command's first path-shaped word. A declared environment stands before the
/// final interpreter word, after that word ([`launch`]).
fn project_command(rel: &str, vars: Option<&BTreeMap<String, String>>) -> String {
    let (walk, run) = project_parts(rel, vars);
    format!("{walk}{run}")
}

/// [`project_command`] as its two halves: the walk that finds the script,
/// and the words that run it once found.
fn project_parts(rel: &str, vars: Option<&BTreeMap<String, String>>) -> (String, String) {
    let walk = format!(
        "p={}; r=$({{ cd -P . && pwd; }} 2>/dev/null); case $r in /*) ;; *) r=;; esac; \
while [ -n \"$r\" ] && ! [ -f \"$r/$p\" ]; do [ \"$r\" = / ] && r= || {{ r=${{r%/*}}; [ -n \"$r\" ] || r=/; }}; done; \
[ -n \"$r\" ] || {{ printf 'kendex-hook-missing: %s\\nNo directory above %s holds this script. Run kendex refresh in the project.\\n' \"$p\" \"$PWD\" >&2; exit 1; }}; ",
        crate::names::quoted(rel),
    );
    let run = format!(
        "{}\"$r/$p\"",
        launch(vars).unwrap_or_else(|| "bash ".to_owned())
    );
    (walk, run)
}

/// The words every Claude Code command that runs an installed hook script
/// opens with: in a Copilot CLI hook process the command exits 0 before its
/// script runs. A custom hook declared as a command is registered as written,
/// without them, and Copilot still runs it.
///
/// Copilot CLI reads the `hooks` of `.claude/settings.json` and
/// `.claude/settings.local.json` at the root of the repository it runs in and
/// runs every entry beside its own. Measured on Copilot CLI 1.0.88: a hook
/// installed for both harnesses then runs twice per event, once from
/// `.github/hooks/` and once from `.claude/hooks/`, and a hook whose
/// `harnesses:` line leaves Copilot out runs anyway, on a Claude-shaped
/// payload that carries no `transcript_path`. Copilot sets
/// `COPILOT_PROJECT_DIR` in the environment of every hook it starts, whatever
/// file registered it, and not in the environment of its tool calls. So a
/// Claude Code session started from a Copilot tool call, which inherits that
/// call's environment, still runs its hooks, and a Copilot session started
/// from a Claude Code tool call skips these commands. Claude Code sets no such
/// variable. Copilot documents none of this. Against the Copilot CLI installed
/// where it runs, `tools/harness-smoke` fails its Copilot `helper:env` row
/// where a tool call carries `COPILOT_PROJECT_DIR`, and its `mixed-hook` rows
/// check that Copilot skips the `.claude/hooks` copies and runs its own while
/// Claude Code runs both; the nested sessions are as measured, and no row
/// re-checks them. Floor: Copilot CLI 1.0.88, the release measured; a
/// release that sets no such variable runs the script as it did before this
/// prefix. The prefix goes once Copilot stops running these registrations or
/// offers a setting that leaves `.claude/settings*.json` hooks out alone.
///
/// The prefix names no path, so [`crate::hook::command_stem`] still names the
/// hook by its script. A registry entry is identified with or without it
/// ([`without_copilot_skip`]).
pub(crate) const CLAUDE_OUTSIDE_COPILOT: &str = "[ -z \"${COPILOT_PROJECT_DIR-}\" ] || exit 0; ";

/// `command` with an opening [`CLAUDE_OUTSIDE_COPILOT`] taken off, and any
/// other command as it is. Claude Code keeps an entry written before the
/// prefix until a refresh rewrites it, and that entry runs the same script.
/// `configedit::nested::hook_key` keys both the upsert and the removal of a
/// nested Claude Code entry through this, a removal by the lock's recorded
/// command included, and `scan::hooks::authored_summary` reads a pre-skip
/// entry's words through it.
pub(crate) fn without_copilot_skip(command: &str) -> &str {
    command
        .strip_prefix(CLAUDE_OUTSIDE_COPILOT)
        .unwrap_or(command)
}

/// A command naming its script outright, `bash "<path>"`, where `path` is
/// already fit to stand inside double quotes. A declared environment binds the
/// path first and stands before the interpreter word, so the script is still
/// the command's first path-shaped word, the one [`crate::hook::command_stem`]
/// names the hook by; an assignment ahead of it could hold a `/` of its own.
fn direct_command(path: &str, vars: Option<&BTreeMap<String, String>>) -> String {
    let (bind, run) = direct_parts(path, vars);
    format!("{bind}{run}")
}

/// [`direct_command`] as its two halves: the binding of the path, empty where
/// nothing is declared, and the words that run the script.
fn direct_parts(path: &str, vars: Option<&BTreeMap<String, String>>) -> (String, String) {
    match launch(vars) {
        None => (String::new(), format!("bash \"{path}\"")),
        Some(launch) => (format!("h=\"{path}\"; "), format!("{launch}\"$h\"")),
    }
}

/// The words ahead of a Copilot hook's run in [`copilot_answer`]. They hold
/// no `/` or `.`, so the script stays the command's first path-shaped word.
const COPILOT_ANSWER_HEAD: &str = "o=$( { e=$(";

/// The words after a Copilot hook's run in [`copilot_answer`], POSIX `sh`
/// throughout. The script's stderr is captured into `e` and its stdout,
/// through fd 3, into `o`, followed by an ASCII record separator and, for a
/// refusal, the reason as a JSON string built by `awk`: backslash and quote
/// escaped, a line break written `\n`, every other control character
/// `\u00XX`, every other byte as it is. `o` is split at the last separator,
/// so a separator the script printed stays the script's.
const COPILOT_ANSWER_TAIL: &str = concat!(
    r#" 2>&1 >&3 3>&-); s=$?; [ -z "$e" ] || printf '%s\n' "$e" >&2; printf '\036'; "#,
    r#"[ "$s" != 2 ] || [ -z "$e" ] || printf '%s\n' "$e" | awk '"#,
    r#"BEGIN{for(i=1;i<32;i++)m[sprintf("%c",i)]=sprintf("\\u%04x",i);"#,
    r#"m["\t"]="\\t";m["\r"]="\\r";m["\\"]="\\\\";m["\""]="\\\"";printf "\""}"#,
    r#"{if(NR>1)printf "\\n";n=length($0);for(i=1;i<=n;i++){c=substr($0,i,1);printf "%s",((c in m)?m[c]:c)}}"#,
    r#"END{printf "\""}'; exit "$s"; } 3>&1 ); s=$?; "#,
    r#"R=$(printf '\036'); a=; case $o in *"$R"*) a=${o##*"$R"}; o=${o%"$R"*} ;; esac; "#,
    r#"case $o in *[![:space:]]*) printf '%s' "$o" ;; "#,
    r#"*) [ -z "$a" ] || printf '{"permissionDecision":"deny","permissionDecisionReason":%s}\n' "$a" ;; esac; "#,
    r#"exit "$s""#,
);

/// A Copilot hook's run, with a refusal handed back where Copilot shows it to
/// the model. Copilot denies a preToolUse call on exit 2 and hands the model
/// only `hook exited with code 2`: stderr never reaches the tool result. What
/// does is `permissionDecisionReason` in a `permissionDecision: "deny"`
/// object on stdout, which Copilot merges with the exit-2 denial
/// ([hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)).
/// So a run that exits 2 with stderr and nothing but whitespace on stdout has
/// that stderr written back as that object; any other run's stdout passes
/// as the script wrote it where it holds a non-space character, the script's
/// own answer included, and is dropped where it is only whitespace. The exit status
/// is always the script's, so a refusal stays a denial and an unexpected
/// failure stays Copilot's `hook errored` denial whether or not the answer
/// could be built, and stderr is replayed for Copilot's log.
///
/// Every Copilot registration of a hook with a script takes this, whatever
/// its event: each reader of a registration asks [`hook_target`] for the
/// command without naming one. A `[[custom-hooks]]` command is registered as
/// written and never takes it. Only preToolUse reads the object: at
/// permissionRequest Copilot takes the denial from `behavior` and `message`.
// REVISIT(D011): drop the answer once Copilot carries stderr into the tool result.
fn copilot_answer(run: &str) -> String {
    format!("{COPILOT_ANSWER_HEAD}{run}{COPILOT_ANSWER_TAIL}")
}

/// The words that start a hook's script under its declared environment,
/// ending ready for its path; `None` where nothing is declared, and the script
/// starts under a bare `bash`. A shell resolves a command word with its
/// assignments in force, so a declared `PATH` would decide where the
/// interpreter is found: the interpreter is resolved first, under the
/// launching environment, and the assignments prefix its resolved path. A
/// launching environment with no `bash` leaves the bare word, found under the
/// declared one, so a declared `PATH` that supplies the interpreter still
/// starts the script and a miss on both names `bash`.
fn launch(vars: Option<&BTreeMap<String, String>>) -> Option<String> {
    let set = assignments(vars);
    (!set.is_empty()).then(|| format!("b=$(command -v bash) || b=bash; {set}\"$b\" "))
}

/// A hook's declared environment as the words that set it for the one command
/// running the script: `NAME=<value> ` per entry in key order, each value
/// through [`crate::names::quoted`] so the shell reads it as the text it is.
/// Validation holds every key to an environment variable name.
fn assignments(vars: Option<&BTreeMap<String, String>>) -> String {
    vars.into_iter()
        .flatten()
        .map(|(key, value)| format!("{key}={} ", crate::names::quoted(value)))
        .collect()
}

/// `vars` is the environment the hook's declaration sets for its script,
/// `None` where nothing declares one.
pub(crate) fn hook_target(
    env: &Env,
    scope: &Scope,
    harness: HarnessId,
    name: &str,
    vars: Option<&BTreeMap<String, String>>,
) -> Option<HookTarget> {
    match harness {
        HarnessId::Claude => {
            let (dir, registry) = match scope {
                Scope::Global => {
                    let root = adapter(harness).default_global_root(env);
                    (root.join("hooks"), root.join("settings.json"))
                }
                Scope::Project { root } => {
                    (root.join(".claude/hooks"), claude_settings(env, scope))
                }
            };
            let path = dir.join(format!("{name}.sh"));
            let command = match scope {
                Scope::Global => direct_command(&crate::paths::slashed(&path), vars),
                Scope::Project { .. } => direct_command(
                    &format!("$CLAUDE_PROJECT_DIR/.claude/hooks/{name}.sh"),
                    vars,
                ),
            };
            let command = format!("{CLAUDE_OUTSIDE_COPILOT}{command}");
            Some(HookTarget::Script {
                path,
                command,
                registry,
                format: HookFormat::Nested,
                feature: None,
            })
        }
        HarnessId::Codex => {
            let root = match scope {
                Scope::Global => adapter(harness).default_global_root(env),
                Scope::Project { root } => root.join(".codex"),
            };
            let path = root.join("hooks").join(format!("{name}.sh"));
            let command = match scope {
                Scope::Global => direct_command(&crate::paths::slashed(&path), vars),
                Scope::Project { .. } => project_command(&format!(".codex/hooks/{name}.sh"), vars),
            };
            Some(HookTarget::Script {
                path,
                command,
                registry: root.join("hooks.json"),
                format: HookFormat::Nested,
                feature: Some(root.join("config.toml")),
            })
        }
        HarnessId::Opencode => {
            let base = match scope {
                Scope::Global => adapter(harness).default_global_root(env),
                Scope::Project { root } => root.join(".opencode"),
            };
            let dir = base.join("instructions");
            let file = format!(
                "{}{name}.md",
                crate::harness::opencode::HOOK_INSTRUCTION_MARKER
            );
            let reference = format!("{}{file}", opencode_instruction_prefix(scope));
            Some(HookTarget::Instruction {
                path: dir.join(&file),
                config: crate::harness::opencode::config_file(env, scope),
                reference,
            })
        }
        HarnessId::Cursor => match scope {
            Scope::Project { root } => Some(HookTarget::Rule {
                path: root
                    .join(".cursor/rules")
                    .join(format!("safety-{name}.mdc")),
            }),
            Scope::Global => None,
        },
        // Gemini registers in the `hooks` key of its settings.json, in the
        // same matcher-plus-handlers shape claude's takes (matrix §1). The
        // script is ours to place; `.gemini/hooks` is not a surface Gemini
        // scans, so nothing reads it except the command we register.
        // Gemini documents no project-directory variable, so the project
        // command finds the root itself (`project_command`).
        HarnessId::Gemini => Some(dotted_script_hook(
            env,
            scope,
            harness,
            name,
            ".gemini",
            "settings.json",
            vars,
        )),
        // Pi executes nothing per hook itself: the pi-hooks carrier's
        // listeners read the registry rendered here and run the scripts.
        // The registry keys are Pi's own listener names — the event was
        // restated before this target is asked for. Both sit under the
        // segment kendex owns: Pi reserved the `hooks/` name beside its
        // own roots (`crate::harness::pi::HOOK_HOME`).
        HarnessId::Pi => Some(pi_hook(env, scope, name, vars)),
        HarnessId::Copilot => Some(copilot_hook(env, scope, name, vars)),
        // Antigravity runs `hooks.json` from the customization root at
        // either scope, the entries keyed by hook name. The loader reads
        // nothing else from a `hooks/` directory beside it, so the script
        // sits there. Its documented project variable is none, so the
        // project command finds the script itself (`project_command`).
        HarnessId::Antigravity => Some(antigravity_hook(env, scope, name, vars)),
    }
}

/// Antigravity's shape: a script under the customization root, registered
/// in the `hooks.json` beside it under the hook's own name.
fn antigravity_hook(
    env: &Env,
    scope: &Scope,
    name: &str,
    vars: Option<&BTreeMap<String, String>>,
) -> HookTarget {
    let root = match scope {
        Scope::Global => adapter(HarnessId::Antigravity).default_global_root(env),
        Scope::Project { root } => root.join(".agents"),
    };
    let path = root.join("hooks").join(format!("{name}.sh"));
    let command = match scope {
        Scope::Global => direct_command(&crate::paths::slashed(&path), vars),
        Scope::Project { .. } => project_command(&format!(".agents/hooks/{name}.sh"), vars),
    };
    HookTarget::Script {
        path,
        command,
        registry: root.join("hooks.json"),
        format: HookFormat::Antigravity,
        feature: None,
    }
}

/// Pi's shape: a script and the carrier's registry, both under the segment
/// kendex owns inside the scope root.
fn pi_hook(
    env: &Env,
    scope: &Scope,
    name: &str,
    vars: Option<&BTreeMap<String, String>>,
) -> HookTarget {
    let root = crate::harness::pi::scope_root(env, scope);
    let path = crate::harness::pi::hook_path(&root, name);
    let command = match scope {
        Scope::Global => direct_command(&crate::paths::slashed(&path), vars),
        Scope::Project { .. } => {
            project_command(&format!(".pi/{}", crate::harness::pi::hook_rel(name)), vars)
        }
    };
    HookTarget::Script {
        path,
        command,
        registry: crate::harness::pi::hook_registry(&root),
        format: HookFormat::Nested,
        feature: None,
    }
}

/// Gemini's shape: a script under the harness's dot-dir, registered in a
/// claude-nested JSON file beside it.
fn dotted_script_hook(
    env: &Env,
    scope: &Scope,
    harness: HarnessId,
    name: &str,
    dot: &str,
    registry_file: &str,
    vars: Option<&BTreeMap<String, String>>,
) -> HookTarget {
    let root = match scope {
        Scope::Global => adapter(harness).default_global_root(env),
        Scope::Project { root } => root.join(dot),
    };
    let path = root.join("hooks").join(format!("{name}.sh"));
    let command = match scope {
        Scope::Global => direct_command(&crate::paths::slashed(&path), vars),
        Scope::Project { .. } => project_command(&format!("{dot}/hooks/{name}.sh"), vars),
    };
    HookTarget::Script {
        path,
        command,
        registry: root.join(registry_file),
        format: HookFormat::Nested,
        feature: None,
    }
}

/// Copilot loads every `*.json` under its hooks directory as a hook document
/// of its own, so each hook gets a file rather than a shared one — and the
/// script beside it is invisible to that glob (matrix §2, §R5). Only a file
/// is a switch: an entry inline in a settings file has no flag to flip.
fn copilot_hook(
    env: &Env,
    scope: &Scope,
    name: &str,
    vars: Option<&BTreeMap<String, String>>,
) -> HookTarget {
    let dir = match scope {
        Scope::Global => adapter(HarnessId::Copilot)
            .default_global_root(env)
            .join("hooks"),
        Scope::Project { root } => root.join(".github/hooks"),
    };
    let path = dir.join(format!("{name}.sh"));
    let (setup, run) = match scope {
        Scope::Global => direct_parts(&crate::paths::slashed(&path), vars),
        Scope::Project { .. } => project_parts(&format!(".github/hooks/{name}.sh"), vars),
    };
    HookTarget::Script {
        path,
        command: format!("{setup}{}", copilot_answer(&run)),
        registry: dir.join(format!("{name}.json")),
        format: HookFormat::Copilot,
        feature: None,
    }
}

/// The settings file carrying claude's hook registrations and plugin toggles.
pub(super) fn claude_settings(env: &Env, scope: &Scope) -> PathBuf {
    match scope {
        Scope::Global => adapter(HarnessId::Claude)
            .default_global_root(env)
            .join("settings.json"),
        Scope::Project { root } => root.join(".claude/settings.json"),
    }
}

/// The file `mcpServers` entries are written to. Claude's project servers
/// belong to the repo's `.mcp.json` and its global ones to the user file;
/// Gemini keeps both in the settings file for that scope (matrix §1).
pub(crate) fn mcp_registry(env: &Env, scope: &Scope, harness: HarnessId) -> Option<PathBuf> {
    match harness {
        HarnessId::Claude => Some(match scope {
            Scope::Global => env.home.join(".claude.json"),
            Scope::Project { root } => root.join(".mcp.json"),
        }),
        HarnessId::Gemini => Some(crate::harness::gemini::settings::settings_file(env, scope)),
        // OpenCode keeps its servers in the scope's one config file, under
        // `mcp` (opencode.ai/docs/mcp-servers).
        HarnessId::Opencode => Some(crate::harness::opencode::config_file(env, scope)),
        // Cursor merges `~/.cursor/mcp.json` with the workspace's
        // `.cursor/mcp.json`, the project entry winning a name clash
        // (cursor.com/docs/mcp).
        HarnessId::Cursor => Some(match scope {
            Scope::Global => adapter(harness).default_global_root(env).join("mcp.json"),
            Scope::Project { root } => root.join(".cursor/mcp.json"),
        }),
        // Antigravity reads `mcp_config.json` under the customization root
        // of either scope (antigravity.google/docs/mcp).
        HarnessId::Antigravity => Some(match scope {
            Scope::Global => adapter(harness)
                .default_global_root(env)
                .join("mcp_config.json"),
            Scope::Project { root } => root.join(".agents/mcp_config.json"),
        }),
        // Codex reads `[mcp_servers.<name>]` from `config.toml` under
        // `CODEX_HOME` and, in a trusted project, from `.codex/config.toml`
        // (learn.chatgpt.com/docs/extend/mcp).
        HarnessId::Codex => Some(match scope {
            Scope::Global => adapter(harness)
                .default_global_root(env)
                .join("config.toml"),
            Scope::Project { root } => root.join(".codex/config.toml"),
        }),
        // Copilot reads a repository's servers from `.github/mcp.json` and a
        // machine's from its own config root (matrix §2). A `.mcp.json` at
        // the repo root is Claude Code's file, which Copilot also reads —
        // writing there would count one declaration as two installations.
        HarnessId::Copilot => Some(match scope {
            Scope::Global => adapter(harness)
                .default_global_root(env)
                .join("mcp-config.json"),
            Scope::Project { root } => root.join(".github/mcp.json"),
        }),
        _ => None,
    }
}

/// The edit that puts one server into a harness's registry, in the key that
/// harness reads it under.
pub(super) fn mcp_upsert(harness: HarnessId, name: &str, value: serde_json::Value) -> ConfigEdit {
    let name = name.to_owned();
    match harness {
        HarnessId::Opencode => ConfigEdit::UpsertOpencodeMcpServer { name, value },
        _ => ConfigEdit::UpsertMcpServer { name, value },
    }
}

/// The edit that takes one server out of a harness's registry.
pub(super) fn mcp_remove(harness: HarnessId, name: &str) -> ConfigEdit {
    let name = name.to_owned();
    match harness {
        HarnessId::Opencode => ConfigEdit::RemoveOpencodeMcpServer { name },
        HarnessId::Codex => ConfigEdit::RemoveCodexMcpServer { name },
        _ => ConfigEdit::RemoveMcpServer { name },
    }
}

/// The settings file whose `enabledPlugins` map a plugin toggle writes.
/// Every harness that reads such a map has one of its own — a declaration
/// aimed at one tool must never land in another tool's settings.
pub(super) fn plugin_settings(env: &Env, scope: &Scope, harness: HarnessId) -> Option<PathBuf> {
    match harness {
        HarnessId::Claude => Some(claude_settings(env, scope)),
        HarnessId::Copilot => Some(crate::harness::copilot::settings::settings_file(env, scope)),
        _ => None,
    }
}

pub(crate) fn disabled_name(path: &std::path::Path) -> PathBuf {
    PathBuf::from(format!("{}.disabled", path.display()))
}

#[cfg(test)]
mod tests;
