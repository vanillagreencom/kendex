//! The copy itself: previewed selections into an authored catalog, with
//! every refusal decided before the first byte is written.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{ItemKind, Scope};

use super::{CandidateGroup, ImportOutcome, ImportSelection, ResolvedSelection};

mod write;
use write::write_all;

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
