//! Taking over a hook somebody registered themselves.
//!
//! A hook is two things: a script, and an entry in each tool's registry
//! pointing at it. Adoption keeps both — the script moves to the shared
//! `.agents/hooks` home, and the declaration becomes a `[[custom-hooks]]`
//! entry, which is how kendex already renders a hook into every tool's own
//! registry dialect. Nothing about the registration is special-cased here:
//! the entries kendex writes are owned by the exact command they run, so
//! the follow-up apply claims the entry by writing the command the script
//! now lives at, and every other entry in the same file is untouched.
//!
//! Only the entry being adopted is ever removed, and only when its command
//! changed — a script that stays where it is keeps its entry, which the
//! next apply simply claims.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::configedit::ConfigEdit;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, CustomHook, HookAgents};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::scan::hooks::{ANY_MATCHER, Registration};

/// Where an adopted hook's script lives: beside the shared skills tree, in
/// the same committed `.agents` home, so a clone carries the script the
/// registrations point at.
const HOME: &str = ".agents/hooks";

/// One tool's copy of the registration being adopted.
struct Found {
    harness: HarnessId,
    registry: PathBuf,
    registration: Registration,
}

/// Plan the adoption of one hook: move its script into the shared home,
/// drop the registration it was under where the command changed, and write
/// the `[[custom-hooks]]` entry the next apply renders from.
pub(super) fn adopt_hook(
    env: &Env,
    scope: &Scope,
    name: &str,
    harnesses: &[HarnessId],
) -> Result<Plan> {
    let mut manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    let found = find(env, scope, name, harnesses)?;
    // One hook, one script. Tools running different commands under one name
    // are different hooks, and only the person can say which to keep.
    let command = found[0].registration.command.clone();
    if let Some(other) = found.iter().find(|f| f.registration.command != command) {
        return Err(CoreError::AdoptedCopiesDiffer {
            name: name.to_owned(),
            first: found[0].harness.display_name().to_owned(),
            second: other.harness.display_name().to_owned(),
        });
    }
    if owned_here(env, scope, &command)? {
        return Err(CoreError::AlreadyManaged {
            name: name.to_owned(),
            path: crate::names::shown(&command),
        });
    }

    let mut ops = Vec::new();
    let moved = script_move(scope, &command, &mut ops)?;
    let command = moved.clone().unwrap_or_else(|| command.clone());
    if moved.is_some() {
        ops.extend(drop_old_entries(&found));
    }

    let event = found[0].registration.event.clone();
    let matcher = match found[0].registration.matcher.as_str() {
        ANY_MATCHER => None,
        held => Some(held.to_owned()),
    };
    let mut wanted: Vec<HarnessId> = found.iter().map(|f| f.harness).collect();
    wanted.dedup();
    manifest.custom_hooks.push(CustomHook {
        // Left to the deterministic derivation the manifest already uses
        // for a hand-written entry, so a plan over this file and the
        // editor's write-back agree on what it is called.
        name: None,
        event,
        matcher,
        command,
        description: Some(format!("adopted from {}", found[0].harness.display_name())),
        timeout: None,
        harnesses: Some(wanted.iter().map(|h| h.name().to_owned()).collect()),
        enabled: true,
        agents: HookAgents::One("all".to_owned()),
    });
    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: "declare the adopted hook in kendex.toml".into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    });
    Ok(Plan {
        scope: scope.clone(),
        ops,
    })
}

/// Every named tool's copy of the registration this name identifies. A tool
/// with nothing under that name is named in the refusal rather than
/// silently dropped: the offer said it had one.
fn find(env: &Env, scope: &Scope, name: &str, harnesses: &[HarnessId]) -> Result<Vec<Found>> {
    let mut found = Vec::new();
    for &harness in harnesses {
        let Some(registry) = registry_of(env, scope, harness) else {
            continue;
        };
        let Some(registration) = read(&registry, harness)
            .into_iter()
            .find(|entry| entry.name() == name)
        else {
            continue;
        };
        found.push(Found {
            harness,
            registry,
            registration,
        });
    }
    if found.is_empty() {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: "no tool here registers a hook by that name".to_owned(),
        });
    }
    Ok(found)
}

/// Every registration in one tool's registry, read the way that tool
/// stores them.
fn read(registry: &Path, harness: HarnessId) -> Vec<Registration> {
    match harness {
        HarnessId::Copilot => crate::scan::copilot::registrations_text(
            &crate::fs::read_if_exists(registry)
                .ok()
                .flatten()
                .unwrap_or_default(),
        )
        .unwrap_or_default(),
        _ => crate::scan::hooks::read_registrations(registry).unwrap_or_default(),
    }
}

/// The file this tool keeps its hook entries in.
fn registry_of(env: &Env, scope: &Scope, harness: HarnessId) -> Option<PathBuf> {
    match crate::engine::targets::hook_target(env, scope, harness, "adopted")? {
        crate::engine::targets::HookTarget::Script { registry, .. } => Some(registry),
        // A tool whose hooks are prose has no registry entry to take over:
        // the instruction file it renders is kendex's own, written from the
        // declaration this adoption is about to make.
        _ => None,
    }
}

/// Whether kendex already registered this command here. Adopting its own
/// entry would fold a managed hook back into the manifest as a foreign one.
fn owned_here(env: &Env, scope: &Scope, command: &str) -> Result<bool> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    Ok(lock.entries.values().any(|entry| {
        entry
            .registration
            .as_ref()
            .is_some_and(|held| held.command == command)
    }))
}

/// Move the script the command runs into the shared home, and hand back the
/// command that reaches it there. `None` where the command runs nothing
/// this project owns — an installed tool, a shell builtin — which is left
/// spelled exactly as it was.
fn script_move(scope: &Scope, command: &str, ops: &mut Vec<PlannedOp>) -> Result<Option<String>> {
    let Scope::Project { root } = scope else {
        return Ok(None);
    };
    let Some((token, path)) = script_token(root, command) else {
        return Ok(None);
    };
    let Some(file) = path.file_name().map(std::ffi::OsString::from) else {
        return Ok(None);
    };
    let home = root.join(HOME).join(&file);
    if home == path {
        return Ok(None);
    }
    if home.exists() {
        return Err(CoreError::AlreadyManaged {
            name: file.to_string_lossy().into_owned(),
            path: crate::names::shown(&home.display().to_string()),
        });
    }
    ops.push(PlannedOp {
        description: format!("move {} into {HOME}", token),
        op: Op::Rename {
            from_pre: Pre::HashIs {
                hash: crate::hash::hash_tree(&path)?,
            },
            to_pre: Pre::Absent,
            from: path,
            to: home,
        },
    });
    Ok(Some(command.replace(
        token,
        &format!("{HOME}/{}", file.to_string_lossy()),
    )))
}

/// The token in a command that names a file inside this project, with the
/// path it resolves to. Only a real file counts: a word that merely looks
/// like a path is somebody's argument, and moving it would break the hook
/// this is meant to preserve.
fn script_token<'a>(root: &Path, command: &'a str) -> Option<(&'a str, PathBuf)> {
    command.split_whitespace().find_map(|token| {
        let bare = token.trim_matches('"').trim_matches('\'');
        if bare != token || !(bare.contains('/') || bare.contains('.')) {
            // Quoted or bare, the same rule — but a quoted token cannot be
            // swapped by text without leaving its quotes behind, so it is
            // left alone rather than half-rewritten.
            return None;
        }
        let path = root.join(bare.trim_start_matches("./"));
        (path.is_file() && path.starts_with(root)).then_some((token, path))
    })
}

/// Drop the entry each tool held under the old command. Grouped per file so
/// two tools sharing a registry edit it once — two edits to one file in one
/// plan is what the collector exists to prevent.
fn drop_old_entries(found: &[Found]) -> Vec<PlannedOp> {
    let mut per_file: BTreeMap<PathBuf, Vec<ConfigEdit>> = BTreeMap::new();
    for entry in found {
        let matcher = match entry.registration.matcher.as_str() {
            ANY_MATCHER => None,
            held => Some(held.to_owned()),
        };
        let edit = match entry.harness {
            HarnessId::Copilot => ConfigEdit::RemoveCopilotHook {
                event: Some(entry.registration.event.clone()),
                matcher,
                command: entry.registration.command.clone(),
            },
            _ => ConfigEdit::RemoveHook {
                event: Some(entry.registration.event.clone()),
                matcher,
                command: entry.registration.command.clone(),
            },
        };
        let edits = per_file.entry(entry.registry.clone()).or_default();
        if !edits.contains(&edit) {
            edits.push(edit);
        }
    }
    per_file
        .into_iter()
        .filter_map(|(path, edits)| {
            Some(PlannedOp {
                description: format!("drop the old registration in {}", path.display()),
                op: Op::EditFile {
                    pre: Pre::observed(&path).ok()?,
                    path,
                    edits,
                },
            })
        })
        .collect()
}

/// The kinds this module answers for, so `supports` and the router never
/// disagree.
pub(super) fn supports(kind: ItemKind) -> bool {
    kind == ItemKind::Hook
}
