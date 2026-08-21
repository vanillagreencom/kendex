//! What one installation put on this machine: the files it wrote, and the
//! structured edits that take its registrations back out.

use std::path::PathBuf;

use super::desired::native_dir;
use super::targets::{HookFormat, HookTarget, hook_target, mcp_registry, plugin_settings};
use crate::configedit::ConfigEdit;
use crate::env::Env;
use crate::lock::LockEntry;
use crate::model::{ItemKind, Scope};
use crate::render::agent::file_name;

pub(super) struct Owned {
    pub(super) files: Vec<PathBuf>,
    pub(super) edits: Vec<(PathBuf, ConfigEdit)>,
}

/// What one installation put on this machine: files it wrote, and the
/// structured edit that takes its registration back out.
pub(super) fn installed(env: &Env, scope: &Scope, entry: &LockEntry) -> Owned {
    let mut files: Vec<PathBuf> = Vec::new();
    let mut edits: Vec<(PathBuf, ConfigEdit)> = Vec::new();
    match entry.kind {
        ItemKind::Agent => {
            if let Some(dir) = native_dir(env, scope, entry.harness, ItemKind::Agent) {
                files.push(dir.join(file_name(entry.harness, &entry.name)));
            }
        }
        ItemKind::Skill => {
            if let Some(dir) = native_dir(env, scope, entry.harness, ItemKind::Skill) {
                files.push(dir.join(crate::harness::rendered_name(entry.harness, &entry.name)));
            }
            // Only a shared install has a shared tree. A copy install put
            // its bytes in the tool's own directory and never wrote that
            // tree, so claiming it here would call somebody else's content
            // ours — and what protects unmanaged bytes is exactly not being
            // called ours.
            if entry.method != crate::manifest::Method::Copy {
                let canonical = super::desired::skill_canonical(env, scope, &entry.name);
                if !files.contains(&canonical) {
                    files.push(canonical);
                }
            }
        }
        // A codex command was written as a skill tree, under a name the
        // collision rules may have changed: the record of what landed
        // beats deriving a path this install never took.
        ItemKind::Command => match &entry.emitted {
            Some(emitted) => files.extend(emitted.paths.iter().cloned()),
            None => {
                if let Some(dir) = native_dir(env, scope, entry.harness, ItemKind::Command) {
                    files.push(dir.join(super::desired_command::command_file(
                        entry.harness,
                        &entry.name,
                    )));
                }
            }
        },
        ItemKind::Hook => hook_owned(env, scope, entry, &mut files, &mut edits),
        ItemKind::McpServer => {
            if let Some(registry) = mcp_registry(env, scope, entry.harness) {
                edits.push((
                    registry,
                    ConfigEdit::RemoveMcpServer {
                        name: entry.name.clone(),
                    },
                ));
            }
            // Gemini's record of whether a server is on lives in a file of
            // its own and would outlive the declaration it describes. That
            // file is one for the whole machine, so only a global-scope
            // removal takes an entry out of it: a project holds the project
            // lock, and clearing the record there would switch a server on
            // everywhere for a removal that was never meant to leave.
            if entry.harness == crate::model::HarnessId::Gemini && matches!(scope, Scope::Global) {
                edits.push((
                    crate::harness::gemini::settings::mcp_enablement_file(env),
                    ConfigEdit::SetGeminiMcpEnabled {
                        name: entry.name.clone(),
                        enabled: None,
                    },
                ));
            }
        }
        ItemKind::Plugin => {
            if let Some(settings) = plugin_settings(env, scope, entry.harness) {
                edits.push((
                    settings,
                    ConfigEdit::SetPluginEnabled {
                        key: entry.name.clone(),
                        enabled: None,
                    },
                ));
            }
        }
        ItemKind::PiExtension => {}
    }
    Owned { files, edits }
}

/// A hook's remains. A script-less hook (custom) registered the person's own
/// command and the lock recorded it, so removal names exactly that entry; a
/// hook with a script re-derives its command from the target it was placed
/// at. Codex's feature flag stays on either way: other hooks may still rely
/// on it, and it enables nothing by itself.
fn hook_owned(
    env: &Env,
    scope: &Scope,
    entry: &LockEntry,
    files: &mut Vec<PathBuf>,
    edits: &mut Vec<(PathBuf, ConfigEdit)>,
) {
    let removal = |event: Option<String>, command: String, format: &HookFormat| match format {
        HookFormat::Nested => ConfigEdit::RemoveHook { event, command },
        HookFormat::Copilot => ConfigEdit::RemoveCopilotHook { event, command },
    };
    match hook_target(env, scope, entry.harness, &entry.name) {
        Some(HookTarget::Script {
            path,
            command,
            registry,
            format,
            ..
        }) => match &entry.registration {
            Some(recorded) => edits.push((
                registry,
                removal(
                    Some(recorded.event.clone()),
                    recorded.command.clone(),
                    &format,
                ),
            )),
            None => {
                files.push(path);
                edits.push((registry, removal(None, command, &format)));
            }
        },
        Some(HookTarget::Instruction {
            path,
            config,
            reference,
        }) => {
            files.push(path);
            edits.push((config, ConfigEdit::OpencodeRemoveInstruction { reference }));
        }
        Some(HookTarget::Rule { path }) => files.push(path),
        None => {}
    }
}
