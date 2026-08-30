//! The copy itself: previewed selections into an authored catalog, with
//! every refusal decided before the first byte is written.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{ItemKind, Scope};

use super::{Bytes, CandidateGroup, ImportOutcome, ImportSelection, ResolvedSelection};

/// Apply the wizard's selections to `target` — a folder registered under
/// Mine, canonicalized, never a symlink. The inventory is re-resolved so
/// every hash is revalidated, and every refusal — an unusable name, a
/// destination already holding other bytes, a licence with no basis — is
/// found before the first byte is written.
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
    write_all(&target, &resolved, selections, &mut outcome)?;
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

/// Write every selection at its destination.
///
/// Two passes, so a refusal reaches nothing: the first decides every one
/// this copy can make — a destination already holding other bytes, a
/// case-folding sibling, a notice file whose bytes differ — and notes the
/// exact copies that are already there; the second writes.
fn write_all(
    target: &Path,
    resolved: &[(usize, ResolvedSelection, PathBuf)],
    selections: &[ImportSelection],
    outcome: &mut ImportOutcome,
) -> Result<()> {
    let mut writes: Vec<(PathBuf, &[u8])> = Vec::new();
    let mut written: Vec<String> = Vec::new();
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
        match &answer.bytes {
            Bytes::File(bytes) => writes.push((dest.clone(), bytes)),
            Bytes::Tree(files) => {
                for (rel, bytes) in files {
                    writes.push((dest.join(rel), bytes));
                }
            }
        }
        written.push(label);
        plan_notices(target, answer, &mut writes, &mut written)?;
    }
    for (dest, bytes) in &writes {
        put(dest, bytes)?;
    }
    outcome.written.extend(written);
    Ok(())
}

/// Licence and attribution files of a licensed origin land under
/// `NOTICES/<source>/`, written once; existing identical bytes are left
/// alone, different bytes refuse.
fn plan_notices<'a>(
    target: &Path,
    answer: &'a ResolvedSelection,
    writes: &mut Vec<(PathBuf, &'a [u8])>,
    written: &mut Vec<String>,
) -> Result<()> {
    let Some((source, _, _)) = answer.group.licensed_source() else {
        return Ok(());
    };
    for (name, bytes) in &answer.notices {
        let dest = target.join("NOTICES").join(source).join(name);
        let label = rel_name(target, &dest);
        if written.contains(&label) {
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
        writes.push((dest, bytes));
        written.push(label);
    }
    Ok(())
}

/// One file at its destination, the directory above it made, and the
/// executable bit kept where the bytes open with a shebang.
fn put(dest: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    }
    std::fs::write(dest, bytes).map_err(|e| CoreError::io(dest, e))?;
    executable_if_script(dest, bytes)
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

/// What the outcome calls one written file: its path under the import
/// target, in the one spelling kendex publishes a path in. Callers read
/// these back against catalog paths, which are `/`-spelled wherever they
/// are written down.
fn rel_name(target: &Path, dest: &Path) -> String {
    crate::paths::slashed(dest.strip_prefix(target).unwrap_or(dest))
}
