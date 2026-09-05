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
                Scope::Project { .. } => {
                    format!("bash \"$(git rev-parse --show-toplevel)/.codex/hooks/{name}.sh\"")
                }
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
        // command resolves through the repo root itself.
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
        // project command resolves through the repo root itself.
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
        Scope::Project { .. } => {
            format!("bash \"$(git rev-parse --show-toplevel)/.agents/hooks/{name}.sh\"")
        }
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
        Scope::Project { .. } => format!(
            "bash \"$(git rev-parse --show-toplevel)/.pi/{}\"",
            crate::harness::pi::hook_rel(name)
        ),
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
        Scope::Project { .. } => {
            format!("bash \"$(git rev-parse --show-toplevel)/{dot}/hooks/{name}.sh\"")
        }
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
    let (dir, command) = match scope {
        Scope::Global => {
            let dir = adapter(HarnessId::Copilot)
                .default_global_root(env)
                .join("hooks");
            let command = format!(
                "bash \"{}\"",
                crate::paths::slashed(&dir.join(format!("{name}.sh")))
            );
            (dir, command)
        }
        Scope::Project { root } => (
            root.join(".github/hooks"),
            format!("bash \"$(git rev-parse --show-toplevel)/.github/hooks/{name}.sh\""),
        ),
    };
    HookTarget::Script {
        path: dir.join(format!("{name}.sh")),
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
