//! Taking the hooks directory back. Removal is receipt-scoped with
//! compare-and-swap on both sides: a user-changed hooksPath survives, and
//! a user-added file turns uninstall into a refusal, never a
//! half-removal. Dead worktrees — leases git's registry no longer lists —
//! are reaped in passing. Without a receipt, ownership is proven by
//! content instead: the config value is ours by name, and a directory
//! holding nothing but byte-identical copies of our own entrypoints is
//! ours by construction — anything else in it stays exactly where it is.

use std::collections::BTreeSet;
use std::path::Path;

use crate::apply::{Op, PlannedOp, Pre};
use crate::error::{CoreError, Result};

use super::{
    HOOKS, NOTHING_INSTALLED, Receipt, Repo, entrypoint, err, load_receipt, old_entrypoint,
    refusals,
};

pub(super) fn plan(repo: &Repo) -> Result<(Vec<PlannedOp>, Vec<String>)> {
    let Some(receipt) = load_receipt(repo)? else {
        return plan_orphan_cleanup(repo);
    };
    let registry: BTreeSet<String> = repo
        .worktrees()?
        .iter()
        .map(|path| path.display().to_string())
        .collect();
    let this = repo.worktree.display().to_string();
    let mut leases = receipt.leases.clone();
    let reaped: Vec<String> = leases
        .iter()
        .filter(|lease| !registry.contains(*lease))
        .cloned()
        .collect();
    for dead in &reaped {
        leases.remove(dead);
    }
    let released = leases.remove(&this);

    let mut lines: Vec<String> = reaped
        .iter()
        .map(|dead| format!("reaped a lease for a worktree git no longer lists: {dead}"))
        .collect();

    if !leases.is_empty() {
        let mut ops = Vec::new();
        if released || !reaped.is_empty() {
            let updated = Receipt {
                leases: leases.clone(),
                ..receipt
            };
            let receipt_path = repo.receipt_path()?;
            ops.push(PlannedOp {
                description: "release this worktree's lease".into(),
                op: Op::WriteFile {
                    pre: Pre::observed(&receipt_path)?,
                    path: receipt_path,
                    bytes: super::render_receipt(&updated)?,
                },
            });
        }
        lines.push(match released {
            true => format!(
                "lease released — the commit checks stay armed for {} other worktree(s)",
                leases.len()
            ),
            false => format!(
                "this worktree never enabled the commit checks; they stay armed for {} worktree(s) — uninstall from one of those to release its lease",
                leases.len()
            ),
        });
        return Ok((ops, lines));
    }

    refusals::check_uninstall(repo, &receipt)?;
    let hooks_dir = repo.hooks_dir()?;
    let mut ops = vec![PlannedOp {
        description: "remove the owned hooks directory".into(),
        op: Op::Trash {
            pre: Pre::HashIs {
                hash: crate::hash::hash_tree(&hooks_dir)?,
            },
            path: hooks_dir,
        },
    }];
    let current = crate::apply::read_git_config(&repo.config_file(), "core.hooksPath")?;
    if current.as_deref() == Some(receipt.hooks_path.as_str()) {
        ops.push(unset_hooks_path(repo, current));
        lines.push("commit checks removed; core.hooksPath unset".into());
    } else {
        lines.push(format!(
            "commit checks removed; core.hooksPath was changed by hand (now {:?}) and was left alone",
            current
        ));
    }
    Ok((ops, lines))
}

fn unset_hooks_path(repo: &Repo, expected: Option<String>) -> PlannedOp {
    PlannedOp {
        description: "unset core.hooksPath".into(),
        op: Op::GitConfigSwap {
            file: repo.config_file(),
            key: "core.hooksPath".into(),
            expected,
            value: None,
        },
    }
}

/// Whether `core.hooksPath` still names either generation's owned
/// directory. A gone directory changes nothing: the value is ours by
/// name, and leaving it makes git run no hooks at all.
fn hooks_path_is_ours(repo: &Repo) -> Result<Option<String>> {
    let current = crate::apply::read_git_config(&repo.config_file(), "core.hooksPath")?;
    Ok(current.filter(|value| {
        repo.generation_dirs()
            .iter()
            .any(|dir| *value == dir.display().to_string())
    }))
}

/// Whether a receiptless repository still carries something of ours to
/// take back: the config value, or a directory of our own entrypoints.
pub(super) fn orphaned(repo: &Repo) -> Result<bool> {
    let hooks_dir = repo.hooks_dir()?;
    Ok(hooks_path_is_ours(repo)?.is_some()
        || (hooks_dir.exists() && foreign_entries(&hooks_dir)?.is_empty()))
}

/// Whether one hook slot is provably ours: a regular file whose bytes
/// are exactly one of our entrypoints under that hook's name. Either
/// generation's bytes count: the vstack-named binary wrote real installs
/// whose receipts can be gone, and their scripts are no less ours for
/// calling the old name.
pub(super) fn written_by_us(name: &str, path: &Path) -> Result<bool> {
    if !HOOKS.contains(&name) || path.is_symlink() || !path.is_file() {
        return Ok(false);
    }
    let bytes = std::fs::read(path).map_err(|e| CoreError::io(path, e))?;
    Ok(bytes == entrypoint(name).into_bytes() || bytes == old_entrypoint(name).into_bytes())
}

/// The entries of a receiptless hooks directory that are not provably
/// ours.
pub(super) fn foreign_entries(hooks_dir: &Path) -> Result<Vec<String>> {
    let entries = std::fs::read_dir(hooks_dir).map_err(|e| CoreError::io(hooks_dir, e))?;
    let mut foreign = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| CoreError::io(hooks_dir, e))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !written_by_us(&name, &entry.path())? {
            foreign.push(name);
        }
    }
    Ok(foreign)
}

/// No receipt. Someone removed files by hand — the whole directory, or
/// just enough of it — and left git resolving hooks from a directory it
/// should not, which silently runs no hook at all, including the user's
/// own. Take back what is provably ours: the config value by name, and
/// the directory only while every entry in it is one of our entrypoints
/// byte for byte. Anything else stays, named, for the user to move.
fn plan_orphan_cleanup(repo: &Repo) -> Result<(Vec<PlannedOp>, Vec<String>)> {
    let hooks_dir = repo.hooks_dir()?;
    let hooks_path = hooks_path_is_ours(repo)?;
    let mut ops = Vec::new();
    let mut lines = Vec::new();
    if hooks_dir.exists() {
        let foreign = foreign_entries(&hooks_dir)?;
        if foreign.is_empty() {
            ops.push(PlannedOp {
                description: "remove the receiptless directory of our own entrypoints".into(),
                op: Op::Trash {
                    pre: Pre::HashIs {
                        hash: crate::hash::hash_tree(&hooks_dir)?,
                    },
                    path: hooks_dir.clone(),
                },
            });
            lines.push(format!(
                "{} carried no receipt but only kendex's own entrypoints; removed",
                hooks_dir.display()
            ));
        } else if hooks_path.is_some() {
            // The directory holds a hook kendex did not write, and
            // `core.hooksPath` is what makes git run it. Unsetting the value
            // and leaving the file would disconnect someone's hook without
            // deleting it — it stays on disk looking installed and never
            // runs again, which is the worst of both. Neither half happens:
            // the whole takeback refuses and names the files.
            return Err(err(format!(
                "{} carries no kendex receipt and holds file(s) kendex cannot prove it wrote ({}) — unsetting core.hooksPath around them would silently stop them running; move them into git's own hooks directory (or delete them) and rerun",
                hooks_dir.display(),
                foreign.join(", ")
            )));
        } else {
            return Err(err(format!(
                "{} carries no kendex receipt and core.hooksPath does not name it — nothing here is provably kendex's; move the directory aside if it is not yours",
                hooks_dir.display()
            )));
        }
    }
    match hooks_path {
        Some(current) => {
            ops.push(unset_hooks_path(repo, Some(current)));
            lines.push(
                "core.hooksPath still named the owned directory with no receipt behind it; unset"
                    .into(),
            );
        }
        None if ops.is_empty() => lines.push(NOTHING_INSTALLED.to_owned()),
        None => {}
    }
    Ok((ops, lines))
}
