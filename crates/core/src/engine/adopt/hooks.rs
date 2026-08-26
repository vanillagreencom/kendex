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
//!
//! Where a registration is read from is the harness's own declared surfaces,
//! the same ones the scan reads: a Copilot hook lives in whichever
//! `.github/hooks/*.json` its author put it in and a Claude one may be in
//! `settings.local.json`, so adoption looks where the row it is answering
//! came from rather than where kendex would have written.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::configedit::ConfigEdit;
use crate::engine::targets::HookFormat;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::harness::{Reader, Surface};
use crate::manifest::{self, CustomHook};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::scan::hooks::{ANY_MATCHER, Registration};

mod declare;
use declare::declaration;

/// Where an adopted hook's script lives: beside the shared skills tree, in
/// the same committed `.agents` home, so a clone carries the script the
/// registrations point at.
const HOME: &str = ".agents/hooks";

/// One tool's copy of the registration being adopted, and the file it was
/// actually read from.
struct Found {
    harness: HarnessId,
    registry: PathBuf,
    format: HookFormat,
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
    // One declaration renders back into every tool's registry, so every
    // entry has to say the same thing — read in the words a declaration is
    // written in, not in each tool's own spelling.
    let declared = declaration(name, &found)?;
    let command = declared.command.clone();
    if owned_here(env, scope, &command)? {
        return Err(CoreError::AlreadyManaged {
            name: name.to_owned(),
            path: crate::names::shown(&command),
        });
    }
    let mut ops = Vec::new();
    let moved = script_move(scope, &command, &mut ops)?;
    if moved.is_some() {
        ops.extend(drop_old_entries(&found)?);
    }
    manifest.custom_hooks.push(CustomHook {
        command: moved.unwrap_or(command),
        ..declared
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

/// Every named tool's copy of the registration this name identifies, read
/// from the files that tool actually keeps hooks in. A tool with nothing
/// under that name is skipped; none of them having one is the refusal.
fn find(env: &Env, scope: &Scope, name: &str, harnesses: &[HarnessId]) -> Result<Vec<Found>> {
    let mut found = Vec::new();
    for &harness in harnesses {
        for (registry, format) in registries(env, scope, harness) {
            let Some(registration) = read(&registry, format)
                .into_iter()
                .find(|entry| entry.name() == name)
            else {
                continue;
            };
            found.push(Found {
                harness,
                registry,
                format,
                registration,
            });
            break;
        }
    }
    if found.is_empty() {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: "no tool here registers a hook by that name".to_owned(),
        });
    }
    Ok(found)
}

/// Every registration in one file, read the way that file is written.
fn read(registry: &Path, format: HookFormat) -> Vec<Registration> {
    match format {
        HookFormat::Copilot => crate::fs::read_if_exists(registry)
            .ok()
            .flatten()
            .and_then(|text| crate::scan::copilot::registrations_text(&text).ok())
            .unwrap_or_default(),
        HookFormat::Nested => crate::scan::hooks::read_registrations(registry).unwrap_or_default(),
    }
}

/// The files this tool keeps hook entries in at this scope, taken from the
/// adapter's own surface declarations — the same list the scan reads, so a
/// row a scan produced can always be found again here. A structured
/// directory contributes every document in it; a surface holding no entries
/// (opencode's instruction files) contributes none.
fn registries(env: &Env, scope: &Scope, harness: HarnessId) -> Vec<(PathBuf, HookFormat)> {
    let adapter = crate::harness::adapter(harness);
    let surfaces = match scope {
        Scope::Global => {
            adapter.global_surfaces(ItemKind::Hook, &adapter.default_global_root(env), env)
        }
        Scope::Project { root } => adapter.project_surfaces(ItemKind::Hook, root, env),
    };
    let mut found = Vec::new();
    for surface in surfaces {
        match surface {
            Surface::Structured { path, reader } => {
                found.extend(format_of(&reader).map(|format| (path, format)));
            }
            Surface::StructuredDir { dir, ext, reader } => {
                let Some(format) = format_of(&reader) else {
                    continue;
                };
                let Ok(entries) = std::fs::read_dir(&dir) else {
                    continue;
                };
                let mut documents: Vec<PathBuf> = entries
                    .flatten()
                    .map(|entry| entry.path())
                    .filter(|path| path.extension().is_some_and(|held| held == ext))
                    .collect();
                documents.sort();
                found.extend(documents.into_iter().map(|path| (path, format)));
            }
            Surface::FileDir { .. } | Surface::SubdirPerItem { .. } => {}
        }
    }
    found
}

/// Which registry shape a reader speaks, or nothing for a reader that holds
/// no hook entries at all.
fn format_of(reader: &Reader) -> Option<HookFormat> {
    match reader {
        Reader::HooksObject => Some(HookFormat::Nested),
        Reader::CopilotHooks => Some(HookFormat::Copilot),
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
        description: format!("move {token} into {HOME}"),
        // The entries as they sit: `hash_tree` follows links, so a script
        // swapped for a link to the same bytes between plan and apply would
        // move the wrong object.
        op: Op::Rename {
            from_pre: Pre::tree_as_is(&path)?,
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

/// The command's script operand and the path it resolves to, or nothing
/// where the command has no shape this can be sure about.
///
/// Two shapes are safe to move: a command that *is* the script
/// (`./hooks/guard.sh --strict`), and a known interpreter's script argument
/// (`bash hooks/guard.sh`, `python3 tools/check.py`). Anything else — a
/// flag's value, a path handed to a program this does not know — is a file
/// the hook reads, not the hook itself, and moving it would break the very
/// thing adoption is preserving. Such a hook is adopted where it stands:
/// the command is declared exactly as written, and nothing moves.
fn script_token<'a>(root: &Path, command: &'a str) -> Option<(&'a str, PathBuf)> {
    let mut tokens = command.split_whitespace();
    let first = tokens.next()?;
    let candidate = match interpreter(first) {
        // The first argument after an interpreter is the script it runs.
        // A flag there (`bash -c '…'`) is a program spelled inline, which
        // has no file to move.
        true => tokens.next().filter(|next| !next.starts_with('-'))?,
        false => first,
    };
    let path = resolved(root, candidate)?;
    path.is_file().then_some((candidate, path))
}

/// Whether this token names an interpreter whose next argument is a script.
/// A short list on purpose: a program not on it may take its arguments in
/// any order, and guessing would move a file the hook only reads.
fn interpreter(token: &str) -> bool {
    let stem = Path::new(token)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    matches!(
        stem.as_str(),
        "bash" | "sh" | "zsh" | "python" | "python3" | "node" | "deno" | "bun"
    )
}

/// Where a token points inside this project, or nothing where it points
/// outside it. Quoted text is left alone — it cannot be swapped by text
/// without leaving its quotes behind — and the containment is decided on
/// the text before any join: a `..` that climbs out and back in resolves to
/// a path inside the root, so a check made after resolving is a check that
/// passes on the way in.
fn resolved(root: &Path, token: &str) -> Option<PathBuf> {
    if token.trim_matches(['"', '\'']) != token {
        return None;
    }
    let bare = token.trim_start_matches("./");
    if !(bare.contains('/') || bare.contains('.')) {
        return None;
    }
    inside(bare).then(|| root.join(bare))
}

/// Whether this text is a plain relative path — every component an ordinary
/// name, no root, no prefix, no `..`. Only such a path stays under the root
/// it is joined onto.
fn inside(text: &str) -> bool {
    let path = Path::new(text);
    !path.is_absolute()
        && path
            .components()
            .all(|component| matches!(component, std::path::Component::Normal(_)))
}

/// Drop the entry each tool held under the old command. Grouped per file so
/// two tools sharing a registry edit it once — two edits to one file in one
/// plan is what the collector exists to prevent.
fn drop_old_entries(found: &[Found]) -> Result<Vec<PlannedOp>> {
    let mut per_file: BTreeMap<PathBuf, Vec<ConfigEdit>> = BTreeMap::new();
    for entry in found {
        let matcher = match entry.registration.matcher.as_str() {
            ANY_MATCHER => None,
            held => Some(held.to_owned()),
        };
        let edit = match entry.format {
            HookFormat::Copilot => ConfigEdit::RemoveCopilotHook {
                event: Some(entry.registration.event.clone()),
                matcher,
                command: entry.registration.command.clone(),
            },
            HookFormat::Nested => ConfigEdit::RemoveHook {
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
        .map(|(path, edits)| {
            Ok(PlannedOp {
                description: format!("drop the old registration in {}", path.display()),
                op: Op::EditFile {
                    pre: Pre::observed(&path)?,
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
