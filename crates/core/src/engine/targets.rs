use std::path::PathBuf;

use crate::configedit::ConfigEdit;
use crate::env::Env;
use crate::harness::{Enforcement, adapter};
use crate::model::{HarnessId, ItemKind, Scope};

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
            "the pi-hooks carrier is not registered in any settings pi loads here — the hook is written but nothing will run it".to_owned(),
            format!("install the {} extension at either scope", crate::pi_ext::carrier::CARRIER),
        ),
        _ => (
            format!(
                "this protection is advisory on {tool} — it installs as text the model may ignore, not a check the tool runs"
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
///
/// `rel` goes through [`crate::names::quoted`], never interpolated inside
/// double quotes, so a segment holding a `$` or a backtick is read as the
/// segment it is. It is assigned first, before the walk, because it is also
/// what names this hook to a reader: [`crate::hook::command_stem`] takes the
/// command's first path-shaped word.
fn project_command(rel: &str) -> String {
    format!(
        "p={}; r=$(cd -P . && pwd); case $r in /*) ;; *) r=;; esac; \
while [ -n \"$r\" ] && ! [ -f \"$r/$p\" ]; do [ \"$r\" = / ] && r= || {{ r=${{r%/*}}; [ -n \"$r\" ] || r=/; }}; done; \
[ -n \"$r\" ] || {{ echo \"kendex: no directory above $PWD holds $p; run kendex refresh in the project\" >&2; exit 1; }}; bash \"$r/$p\"",
        crate::names::quoted(rel),
    )
}

pub(crate) fn hook_target(
    env: &Env,
    scope: &Scope,
    harness: HarnessId,
    name: &str,
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
                Scope::Global => format!("bash \"{}\"", crate::paths::slashed(&path)),
                Scope::Project { .. } => {
                    format!("bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/{name}.sh\"")
                }
            };
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
                Scope::Global => format!("bash \"{}\"", crate::paths::slashed(&path)),
                Scope::Project { .. } => project_command(&format!(".codex/hooks/{name}.sh")),
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
        )),
        // Pi executes nothing per hook itself: the pi-hooks carrier's
        // listeners read the registry rendered here and run the scripts.
        // The registry keys are Pi's own listener names — the event was
        // restated before this target is asked for. Both sit under the
        // segment kendex owns: Pi reserved the `hooks/` name beside its
        // own roots (`crate::harness::pi::HOOK_HOME`).
        HarnessId::Pi => Some(pi_hook(env, scope, name)),
        HarnessId::Copilot => Some(copilot_hook(env, scope, name)),
        // Antigravity runs `hooks.json` from the customization root at
        // either scope, the entries keyed by hook name. The loader reads
        // nothing else from a `hooks/` directory beside it, so the script
        // sits there. Its documented project variable is none, so the
        // project command finds the script itself (`project_command`).
        HarnessId::Antigravity => Some(antigravity_hook(env, scope, name)),
    }
}

/// Antigravity's shape: a script under the customization root, registered
/// in the `hooks.json` beside it under the hook's own name.
fn antigravity_hook(env: &Env, scope: &Scope, name: &str) -> HookTarget {
    let root = match scope {
        Scope::Global => adapter(HarnessId::Antigravity).default_global_root(env),
        Scope::Project { root } => root.join(".agents"),
    };
    let path = root.join("hooks").join(format!("{name}.sh"));
    let command = match scope {
        Scope::Global => format!("bash \"{}\"", crate::paths::slashed(&path)),
        Scope::Project { .. } => project_command(&format!(".agents/hooks/{name}.sh")),
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
fn pi_hook(env: &Env, scope: &Scope, name: &str) -> HookTarget {
    let root = crate::harness::pi::scope_root(env, scope);
    let path = crate::harness::pi::hook_path(&root, name);
    let command = match scope {
        Scope::Global => format!("bash \"{}\"", crate::paths::slashed(&path)),
        Scope::Project { .. } => {
            project_command(&format!(".pi/{}", crate::harness::pi::hook_rel(name)))
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
) -> HookTarget {
    let root = match scope {
        Scope::Global => adapter(harness).default_global_root(env),
        Scope::Project { root } => root.join(dot),
    };
    let path = root.join("hooks").join(format!("{name}.sh"));
    let command = match scope {
        Scope::Global => format!("bash \"{}\"", crate::paths::slashed(&path)),
        Scope::Project { .. } => project_command(&format!("{dot}/hooks/{name}.sh")),
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
fn copilot_hook(env: &Env, scope: &Scope, name: &str) -> HookTarget {
    let dir = match scope {
        Scope::Global => adapter(HarnessId::Copilot)
            .default_global_root(env)
            .join("hooks"),
        Scope::Project { root } => root.join(".github/hooks"),
    };
    let path = dir.join(format!("{name}.sh"));
    let command = match scope {
        Scope::Global => format!("bash \"{}\"", crate::paths::slashed(&path)),
        Scope::Project { .. } => project_command(&format!(".github/hooks/{name}.sh")),
    };
    HookTarget::Script {
        path,
        command,
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
pub(super) fn mcp_registry(env: &Env, scope: &Scope, harness: HarnessId) -> Option<PathBuf> {
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

pub(super) fn disabled_name(path: &std::path::Path) -> PathBuf {
    PathBuf::from(format!("{}.disabled", path.display()))
}

#[cfg(test)]
mod tests;
