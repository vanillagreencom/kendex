//! What an older kendex left in the directory name Pi has since reserved.
//!
//! Pi prints a migration warning for any `hooks/` sitting directly beside
//! a root it loads. The check is existence only — it never looks inside —
//! and the migration it names, into `extensions/`, is one kendex hooks
//! cannot take: they are shell scripts the `pi-hooks` carrier runs, not Pi
//! extensions. The storage moved under a segment kendex owns
//! (`crate::harness::pi::HOOK_HOME`); the copies an earlier kendex wrote
//! come off disk here, and the directory goes with them — emptying it
//! leaves the warning exactly where it was.

use std::collections::BTreeSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

use crate::apply::PlannedOp;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::lock::{Lock, LockEntry};
use crate::model::{HarnessId, ItemKind, Scope};

/// The directory name Pi reserved, and the registry an earlier kendex
/// wrote beside it.
const LEGACY_DIR: &str = "hooks";
const LEGACY_REGISTRY: &str = "hooks.json";

/// The ops that take the old layout off disk, plus a line for anything
/// that had to stay. The same plan writes every still-declared hook at
/// the new path, so nothing is planned to carry content across.
pub(super) fn plan_move(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    ops: &mut Vec<PlannedOp>,
    notes: &mut Vec<String>,
) -> Result<()> {
    let root = match scope {
        Scope::Global => crate::harness::adapter(HarnessId::Pi).default_global_root(env),
        Scope::Project { root } => root.join(".pi"),
    };
    // A lock entry is the only proof kendex wrote here. With none, a
    // `hooks/` beside this root is somebody else's directory and a
    // `hooks.json` beside it is somebody else's file: both stay.
    let entries: Vec<&LockEntry> = lock
        .entries
        .values()
        .filter(|entry| entry.kind == ItemKind::Hook && entry.harness == HarnessId::Pi)
        .collect();
    if entries.is_empty() {
        return Ok(());
    }
    let dir = root.join(LEGACY_DIR);
    let registry = root.join(LEGACY_REGISTRY);

    let mut mine: BTreeSet<OsString> = BTreeSet::new();
    for entry in entries {
        for file in [
            format!("{}.sh", entry.name),
            format!("{}.sh.disabled", entry.name),
        ] {
            let path = dir.join(&file);
            if !path.is_file() {
                continue;
            }
            // A record from before `rendered_hash` existed cannot prove
            // the bytes are ours, and the move takes them anyway — into
            // the trash, with a fresh copy written at the new path. Only
            // a proven mismatch is somebody's edit, and that file stays
            // where it is rather than losing work nobody looked at.
            if edited(entry, &path) {
                notes.push(format!(
                    "{} was edited on disk, so it stayed in the directory pi reserved — copy your changes into {} and delete the old file",
                    path.display(),
                    crate::harness::pi::hook_dir(&root).join(&file).display()
                ));
                continue;
            }
            mine.insert(OsString::from(file));
        }
    }

    if dir.is_dir() {
        let strangers = strangers(&dir, &mine)?;
        if strangers.is_empty() {
            ops.push(trash(
                format!("Move pi hooks out of {}", dir.display()),
                dir.clone(),
            )?);
        } else {
            for file in &mine {
                ops.push(trash(
                    format!("Move pi hooks out of {}", dir.display()),
                    dir.join(file),
                )?);
            }
            notes.push(format!(
                "{} also holds files kendex did not write ({}) — pi keeps warning about the directory until they are moved or removed by hand",
                dir.display(),
                strangers.join(", ")
            ));
        }
    }
    if registry.is_file() {
        ops.push(trash(
            format!("Move the pi hook registry out of {}", registry.display()),
            registry,
        )?);
    }
    Ok(())
}

/// Whether the bytes at `path` are not the ones apply last wrote there.
fn edited(entry: &LockEntry, path: &Path) -> bool {
    let Some(rendered) = &entry.rendered_hash else {
        return false;
    };
    crate::hash::hash_tree(path)
        .map(|disk| &disk != rendered)
        .unwrap_or(true)
}

/// Everything in the reserved directory that is not kendex's to take.
fn strangers(dir: &Path, mine: &BTreeSet<OsString>) -> Result<Vec<String>> {
    let mut strangers: Vec<String> = Vec::new();
    for entry in std::fs::read_dir(dir).map_err(|e| CoreError::io(dir, e))? {
        let name = entry.map_err(|e| CoreError::io(dir, e))?.file_name();
        if !mine.contains(&name) {
            strangers.push(name.to_string_lossy().into_owned());
        }
    }
    strangers.sort();
    Ok(strangers)
}

/// A trash op bound to the bytes the preview showed, like every other
/// removal (invariant 7).
fn trash(description: String, path: PathBuf) -> Result<PlannedOp> {
    Ok(PlannedOp {
        description,
        op: crate::apply::Op::Trash {
            pre: crate::apply::Pre::HashIs {
                hash: crate::hash::hash_tree(&path)?,
            },
            path,
        },
    })
}
