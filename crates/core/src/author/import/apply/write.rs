//! Putting the bytes down: what each selection writes, where, and the
//! collisions decided before the first one lands.

use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};

use super::super::{Bytes, ImportOutcome, ImportSelection, ResolvedSelection};

/// One file this copy will write: where it goes, its bytes, and the
/// package the outcome names it under.
struct Write<'a> {
    dest: PathBuf,
    bytes: &'a [u8],
    label: String,
}

impl<'a> Write<'a> {
    fn new(dest: PathBuf, bytes: &'a [u8], label: &str) -> Write<'a> {
        Write {
            dest,
            bytes,
            label: label.to_owned(),
        }
    }
}

/// Write every selection at its destination.
///
/// Two passes, so a refusal reaches nothing: the first decides every one
/// this copy can make — a destination already holding other bytes, a
/// case-folding sibling — and notes the exact copies that are already
/// there; the second writes. Two selections claiming one place is decided
/// before either reaches here, by the caller, over the selections
/// themselves.
///
/// A disk that fails in the second pass is not a refusal and is not
/// undone. The error names what reached the folder, because the next
/// attempt reads those bytes as somebody else's.
pub(super) fn write_all(
    target: &Path,
    resolved: &[(usize, ResolvedSelection, PathBuf)],
    selections: &[ImportSelection],
    outcome: &mut ImportOutcome,
) -> Result<()> {
    let mut planned: Vec<Write<'_>> = Vec::new();
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
            Bytes::File(bytes) => planned.push(Write::new(dest.clone(), bytes, &label)),
            Bytes::Tree(files) => {
                for (rel, bytes) in files {
                    planned.push(Write::new(dest.join(rel), bytes, &label));
                }
            }
        }
        outcome.written.push(label);
        plan_notices(target, answer, &mut planned, outcome)?;
    }
    for (index, write) in planned.iter().enumerate() {
        if let Err(error) = put(&write.dest, write.bytes) {
            return Err(interrupted(&planned[..index], write, error));
        }
    }
    Ok(())
}

/// Licence and attribution files of a licensed origin land under
/// `NOTICES/<source>/`, written once; existing identical bytes are left
/// alone, different bytes refuse.
fn plan_notices<'a>(
    target: &Path,
    answer: &'a ResolvedSelection,
    planned: &mut Vec<Write<'a>>,
    outcome: &mut ImportOutcome,
) -> Result<()> {
    let Some((source, _, _)) = answer.group.licensed_source() else {
        return Ok(());
    };
    for (name, bytes) in &answer.notices {
        let dest = target.join("NOTICES").join(source).join(name);
        // The path is what a write is claimed under, so the question is
        // asked of it rather than of the label it renders as. A shared
        // licence file reached through two origins is one write.
        if planned.iter().any(|held| held.dest == dest) {
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
        let label = rel_name(target, &dest);
        planned.push(Write::new(dest, bytes, &label));
        outcome.written.push(label);
    }
    Ok(())
}

/// A write that stopped part-way, said so that the folder can be put
/// right. What already landed is still there, and the next attempt would
/// read those bytes as somebody else's and blame the person for them.
fn interrupted(done: &[Write<'_>], failing: &Write<'_>, error: CoreError) -> CoreError {
    let mut landed: Vec<&str> = Vec::new();
    for write in done.iter().chain(std::iter::once(failing)) {
        if !landed.contains(&write.label.as_str()) {
            landed.push(&write.label);
        }
    }
    CoreError::Authoring {
        message: format!(
            "writing {} failed ({error}). These are partly or wholly in the folder now: {}. Remove them before importing again.",
            failing.dest.display(),
            landed.join(", ")
        ),
    }
}

/// One file at its destination, the directory above it made, and the
/// executable bit kept where the bytes open with a shebang.
fn put(dest: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    }
    std::fs::write(dest, bytes).map_err(|e| CoreError::io(dest, e))?;
    crate::fs::executable_if_script(dest, bytes)
}

/// A sibling whose name folds to the destination's spelling occupies it on
/// a case-insensitive filesystem — refused before the copy, naming both.
fn fold_collision(dest: &Path, name: &str) -> Result<()> {
    let Some(sibling) = crate::names::folding_sibling(dest)? else {
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

/// What the outcome calls one written file: its path under the import
/// target, in the one spelling kendex publishes a path in. Callers read
/// these back against catalog paths, which are `/`-spelled wherever they
/// are written down.
fn rel_name(target: &Path, dest: &Path) -> String {
    crate::paths::slashed(dest.strip_prefix(target).unwrap_or(dest))
}
