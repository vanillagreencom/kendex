//! The copy itself: previewed selections into an authored catalog, with
//! every refusal decided before the first byte is written, the whole
//! output staged inside the target, and each package moved into place by
//! one rename after the last stage write succeeded.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{ItemKind, Scope};

use super::{Bytes, CandidateGroup, ImportOutcome, ImportSelection, ResolvedSelection};

/// Apply the wizard's selections to `target` — a folder registered under
/// Mine, canonicalized, never a symlink. The inventory is re-resolved so
/// every hash is revalidated; all refusals are found before anything is
/// written, the files are staged under the target, and each package
/// arrives by rename. A refused apply writes nothing.
pub fn apply(
    env: &Env,
    scopes: &[Scope],
    target: &Path,
    selections: &[ImportSelection],
) -> Result<ImportOutcome> {
    let target = registered_target(env, target)?;
    let mut resolved: Vec<(usize, ResolvedSelection, PathBuf)> = Vec::new();
    let mut taken: BTreeSet<(ItemKind, String)> = BTreeSet::new();
    for (at, selection) in selections.iter().enumerate() {
        if let Some(problem) = crate::names::item_problem(&selection.destination) {
            return Err(CoreError::Authoring {
                message: format!(
                    "'{}' cannot name an imported {} — {problem}",
                    selection.destination,
                    selection.kind.name()
                ),
            });
        }
        if !matches!(
            selection.kind,
            ItemKind::Skill
                | ItemKind::Agent
                | ItemKind::Hook
                | ItemKind::Command
                | ItemKind::McpServer
        ) {
            return Err(CoreError::Authoring {
                message: format!(
                    "a {} cannot be imported into a catalog directly",
                    selection.kind.name()
                ),
            });
        }
        // Two selections folding to one destination would silently
        // overwrite each other during the copy — refused up front.
        let key = (selection.kind, crate::names::fold(&selection.destination));
        if !taken.insert(key) {
            return Err(CoreError::Authoring {
                message: format!(
                    "two selections both land at {} '{}' — give one a different destination name",
                    selection.kind.name(),
                    selection.destination
                ),
            });
        }
        let answer = super::resolve_selection(env, scopes, selection)?;
        license_gate(selection, &answer.group)?;
        let dest = destination(&target, selection.kind, &selection.destination);
        origin_overlap(&target, &answer)?;
        resolved.push((at, answer, dest));
    }

    let mut outcome = ImportOutcome {
        written: Vec::new(),
        already_present: Vec::new(),
    };
    let staging = target.join(".kendex-import-staging");
    if staging.exists() {
        std::fs::remove_dir_all(&staging).map_err(|e| CoreError::io(&staging, e))?;
    }
    let staged = stage(&target, &staging, &resolved, selections, &mut outcome);
    let landed = staged.and_then(|staged| land(&target, staged, &mut outcome));
    let _ = std::fs::remove_dir_all(&staging);
    landed?;
    Ok(outcome)
}

/// Imports write only into a folder the person registered — and into its
/// real self, never through a symlink.
fn registered_target(env: &Env, target: &Path) -> Result<PathBuf> {
    let canonical = target
        .canonicalize()
        .map_err(|e| CoreError::io(target, e))?;
    if target
        .symlink_metadata()
        .map(|meta| meta.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err(CoreError::Authoring {
            message: format!(
                "{} is a symlink — import into the real folder",
                target.display()
            ),
        });
    }
    if !super::super::registry::list(env)?.contains(&canonical) {
        return Err(CoreError::Authoring {
            message: format!(
                "{} is not under Mine — register it first (kendex marketplace use) or create one",
                target.display()
            ),
        });
    }
    Ok(canonical)
}

/// A copy must not write back into the tree it reads: an origin path
/// inside the target, or one whose tree contains the target, is refused.
fn origin_overlap(target: &Path, answer: &ResolvedSelection) -> Result<()> {
    let Some(read_from) = &answer.read_from else {
        return Ok(());
    };
    let read = read_from
        .canonicalize()
        .unwrap_or_else(|_| read_from.clone());
    let read_tree = match read.is_dir() {
        true => read.as_path(),
        false => read.parent().unwrap_or(read.as_path()),
    };
    if read.starts_with(target) || target.starts_with(read_tree) {
        return Err(CoreError::Authoring {
            message: format!(
                "{} is inside the tree the bytes come from ({}) — a copy cannot write back into its own origin",
                target.display(),
                read.display()
            ),
        });
    }
    Ok(())
}

/// Licensed-origin content copies only past licence evidence: a shown,
/// *recognized* licence the person confirmed, or an explicit basis they
/// stated. Confirmation never synthesizes permission — an unrecognized
/// licence cannot be checkbox-approved.
fn license_gate(selection: &ImportSelection, group: &CandidateGroup) -> Result<()> {
    let Some((source, license, recognized)) = group.licensed_source() else {
        return Ok(());
    };
    let basis_given = selection
        .license_basis
        .as_deref()
        .map(str::trim)
        .is_some_and(|basis| !basis.is_empty());
    match license {
        Some(license) if recognized => match selection.license_confirmed {
            true => Ok(()),
            false => Err(CoreError::Authoring {
                message: format!(
                    "'{}' comes from marketplace '{source}' under licence {license} — confirm the licence permits republishing, or pick another origin",
                    selection.name
                ),
            }),
        },
        Some(license) if basis_given => {
            let _ = license;
            Ok(())
        }
        Some(license) => Err(CoreError::Authoring {
            message: format!(
                "'{}' comes from marketplace '{source}' under '{license}', which kendex does not recognize as redistributable — state your basis for copying it (--license-basis), or pick another origin",
                selection.name
            ),
        }),
        None if basis_given => Ok(()),
        None => Err(CoreError::Authoring {
            message: format!(
                "'{}' comes from marketplace '{source}' with no detectable licence — state your basis for copying it (--license-basis), or pick another origin",
                selection.name
            ),
        }),
    }
}

/// Where each kind lands inside a catalog.
fn destination(target: &Path, kind: ItemKind, name: &str) -> PathBuf {
    match kind {
        ItemKind::Skill => target.join("skills").join(name),
        ItemKind::Agent => target.join("agents").join(format!("{name}.md")),
        ItemKind::Hook => target.join("hooks").join(format!("{name}.sh")),
        ItemKind::Command => target.join("commands").join(format!("{name}.md")),
        ItemKind::McpServer => target.join("mcp").join(format!("{name}.toml")),
        ItemKind::Plugin | ItemKind::PiExtension => target.join(name),
    }
}

/// One staged package ready to land: where it is now, where it goes.
struct StagedWrite {
    from: PathBuf,
    to: PathBuf,
    label: String,
}

/// Write every selection under the staging dir. Already-present exact
/// bytes are noted and skipped; a destination holding different bytes, or
/// a case-folding sibling, refuses here — before anything lands.
fn stage(
    target: &Path,
    staging: &Path,
    resolved: &[(usize, ResolvedSelection, PathBuf)],
    selections: &[ImportSelection],
    outcome: &mut ImportOutcome,
) -> Result<Vec<StagedWrite>> {
    let mut staged = Vec::new();
    for (at, answer, dest) in resolved {
        let selection = &selections[*at];
        let label = rel_name(target, dest);
        fold_collision(dest, &selection.destination)?;
        if dest.symlink_metadata().is_ok() {
            let same = match &answer.bytes {
                Bytes::File(bytes) => std::fs::read(dest)
                    .map(|existing| existing == *bytes)
                    .unwrap_or(false),
                Bytes::Tree(files) => {
                    crate::hash::hash_tree(dest).unwrap_or_default()
                        == crate::hash::hash_files(files)
                }
            };
            match same {
                true => outcome.already_present.push(label),
                false => return Err(occupied(dest, &selection.name)),
            }
            continue;
        }
        let from = staging.join(format!("{at}")).join(
            dest.file_name()
                .map(|leaf| leaf.to_os_string())
                .unwrap_or_default(),
        );
        match &answer.bytes {
            Bytes::File(bytes) => {
                if let Some(parent) = from.parent() {
                    std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
                }
                std::fs::write(&from, bytes).map_err(|e| CoreError::io(&from, e))?;
                executable_if_script(&from, bytes)?;
            }
            Bytes::Tree(files) => {
                for (rel, bytes) in files {
                    let file = from.join(rel);
                    if let Some(parent) = file.parent() {
                        std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
                    }
                    std::fs::write(&file, bytes).map_err(|e| CoreError::io(&file, e))?;
                    executable_if_script(&file, bytes)?;
                }
            }
        }
        staged.push(StagedWrite {
            from,
            to: dest.clone(),
            label,
        });
        stage_notices(target, staging, answer, outcome, &mut staged)?;
    }
    Ok(staged)
}

/// Licence and attribution files of a licensed origin land under
/// `NOTICES/<source>/`, written once; existing identical bytes are left
/// alone, different bytes refuse.
fn stage_notices(
    target: &Path,
    staging: &Path,
    answer: &ResolvedSelection,
    outcome: &mut ImportOutcome,
    staged: &mut Vec<StagedWrite>,
) -> Result<()> {
    let Some((source, _, _)) = answer.group.licensed_source() else {
        return Ok(());
    };
    for (name, bytes) in &answer.notices {
        let dest = target.join("NOTICES").join(source).join(name);
        let label = rel_name(target, &dest);
        if staged.iter().any(|write| write.to == dest) {
            continue;
        }
        if dest.symlink_metadata().is_ok() {
            let same = std::fs::read(&dest)
                .map(|existing| existing == *bytes)
                .unwrap_or(false);
            if !same {
                return Err(occupied(&dest, name));
            }
            continue;
        }
        let from = staging.join("notices").join(source).join(name);
        if let Some(parent) = from.parent() {
            std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
        }
        std::fs::write(&from, bytes).map_err(|e| CoreError::io(&from, e))?;
        outcome.written.push(label.clone());
        staged.push(StagedWrite {
            from,
            to: dest,
            label,
        });
    }
    Ok(())
}

/// Move every staged package into place. Each destination is re-verified
/// as still absent right before its rename, so bytes that appeared during
/// staging refuse instead of being replaced.
fn land(target: &Path, staged: Vec<StagedWrite>, outcome: &mut ImportOutcome) -> Result<()> {
    let _ = target;
    for write in staged {
        if write.to.symlink_metadata().is_ok() {
            return Err(CoreError::Authoring {
                message: format!(
                    "{} appeared while the import was being prepared — nothing more was written",
                    write.to.display()
                ),
            });
        }
        if let Some(parent) = write.to.parent() {
            std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
        }
        std::fs::rename(&write.from, &write.to).map_err(|e| CoreError::io(&write.to, e))?;
        if !outcome.written.contains(&write.label) {
            outcome.written.push(write.label);
        }
    }
    Ok(())
}

/// A sibling whose name folds to the destination's spelling occupies it on
/// a case-insensitive filesystem — refused before the copy, naming both.
fn fold_collision(dest: &Path, name: &str) -> Result<()> {
    let Some(sibling) = crate::names::folding_sibling(dest) else {
        return Ok(());
    };
    let sibling = sibling
        .file_name()
        .map(|leaf| leaf.to_string_lossy().into_owned())
        .unwrap_or_default();
    Err(CoreError::Authoring {
        message: format!(
            "'{name}' would collide with existing '{sibling}' on a case-insensitive filesystem — pick another destination name"
        ),
    })
}

fn occupied(dest: &Path, name: &str) -> CoreError {
    CoreError::Authoring {
        message: format!(
            "{} already holds different bytes than '{name}' — rename the import destination or remove the existing file first",
            dest.display()
        ),
    }
}

/// A file whose bytes open with a shebang was written to be run — the
/// copy keeps that runnable.
fn executable_if_script(path: &Path, bytes: &[u8]) -> Result<()> {
    if !bytes.starts_with(b"#!") {
        return Ok(());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| CoreError::io(path, e))?;
    }
    Ok(())
}

fn rel_name(target: &Path, dest: &Path) -> String {
    dest.strip_prefix(target)
        .unwrap_or(dest)
        .display()
        .to_string()
}
