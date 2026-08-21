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
            let canonical = super::desired::skill_canonical(env, scope, &entry.name);
            if !files.contains(&canonical) {
                files.push(canonical);
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

/// A hook's remains: the entry it registered, and the script it wrote if
/// it wrote one.
///
/// Which of those two shapes it is reads off the record, not off the
/// registration alone — every hook that registers something records what
/// it registered, and only a hook with no script of its own leaves no
/// `rendered_hash` behind. The registration is named by the record where
/// there is one, so an entry whose event has changed since it went in
/// still comes out; an entry from before the record was kept is named by
/// the command this path spells, as it always was. Codex's feature flag
/// stays on either way: other hooks may still rely on it, and it enables
/// nothing by itself.
fn hook_owned(
    env: &Env,
    scope: &Scope,
    entry: &LockEntry,
    files: &mut Vec<PathBuf>,
    edits: &mut Vec<(PathBuf, ConfigEdit)>,
) {
    let removal = |event: Option<String>, command: String, format: &HookFormat| match format {
        // The whole installation is going, so its command goes wherever
        // it is registered: an entry left behind would name a script that
        // is no longer there.
        HookFormat::Nested => ConfigEdit::RemoveHook {
            event,
            matcher: None,
            command,
        },
        HookFormat::Copilot => ConfigEdit::RemoveCopilotHook {
            event,
            matcher: None,
            command,
        },
    };
    match hook_target(env, scope, entry.harness, &entry.name) {
        Some(HookTarget::Script {
            path,
            command,
            registry,
            format,
            ..
        }) => {
            // A hook with no script of its own is that registration and
            // nothing else; everything else wrote a file, and the entry
            // that runs it comes out with it.
            if entry.rendered_hash.is_some() || entry.registration.is_none() {
                files.push(path);
            }
            let (event, command) = match &entry.registration {
                // A hook with no script of its own is that entry and
                // nothing else, so it comes out by the identity the
                // record kept, exactly.
                Some(recorded) if entry.rendered_hash.is_none() => {
                    (Some(recorded.event.clone()), recorded.command.clone())
                }
                // A hook whose script goes with it takes its registration
                // wherever that has got to. An entry taken from an event
                // somebody moved it to is a smaller wrong than a command
                // left pointing at a script that is no longer there — and
                // the command is the record's, which is what kendex
                // registered, not what it would render today.
                Some(recorded) => (None, recorded.command.clone()),
                None => (None, command),
            };
            edits.push((registry, removal(event, command, &format)));
        }
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
