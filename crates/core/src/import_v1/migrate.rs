//! The one-shot v1 → v2 migration of a scope, as core logic the CLI and
//! the app both call thin (GUI + CLI are equal shells). Fail-closed
//! throughout (the #1307 class): a damaged record refuses instead of
//! reading as absent, a live destination refuses instead of being
//! re-imported over, and every precondition binds to the exact bytes this
//! pass classified — a concurrent write lands as PlanStale, never a
//! silent clobber.

use std::path::PathBuf;

use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;
use crate::{lock, manifest};

fn err(scope: &Scope, message: impl std::fmt::Display) -> CoreError {
    crate::guard::guard_err("import", format!("{}: {message}", scope.label()))
}

/// Where v1 kept this scope's lock. A project shares the v2 path; the
/// global scopes differ.
pub fn v1_lock_path(env: &Env, scope: &Scope) -> PathBuf {
    match scope {
        Scope::Global => env.platform_config_dir().join("vstack/.vstack-lock.json"),
        Scope::Project { root } => root.join(".vstack-lock.json"),
    }
}

/// What one scope's migration did.
#[derive(Debug)]
pub struct Migration {
    pub notes: Vec<String>,
    /// Lock entries migrated; `None` = nothing v1 was found here.
    pub migrated: Option<usize>,
}

/// A file's bytes and the precondition that binds to exactly them.
struct ReadBytes {
    text: Option<String>,
    pre: Pre,
}

fn read_bound(path: &std::path::Path) -> Result<ReadBytes> {
    let text = crate::fs::read_if_exists(path)?;
    let pre = match &text {
        None => Pre::Absent,
        Some(text) => Pre::HashIs {
            hash: crate::hash::hash_bytes(text.as_bytes()),
        },
    };
    Ok(ReadBytes { text, pre })
}

fn backup(env: &Env, path: &std::path::Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let trash = env.trash_dir();
    std::fs::create_dir_all(&trash).map_err(|e| CoreError::io(&trash, e))?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "v1-file".to_owned());
    let stamp = crate::clock::timestamp().replace(':', "-");
    let dest = trash.join(format!("{stamp}-v1-{name}"));
    std::fs::copy(path, &dest).map_err(|e| CoreError::io(path, e))?;
    Ok(())
}

/// Migrate one scope. `Ok(Migration { migrated: None, .. })` means the
/// scope had nothing v1 to convert; every refusal is an `Err` naming what
/// to do, so a caller can note it and continue with other scopes.
pub fn migrate_scope(env: &Env, scope: &Scope) -> Result<Migration> {
    let mut notes = Vec::new();
    let manifest_path = manifest::manifest_path(env, scope);
    let manifest_read = read_bound(&manifest_path)?;
    let manifest_file = match &manifest_read.text {
        None => manifest::ManifestFile::Absent,
        // Classified from the same bytes the precondition binds to.
        Some(text) => manifest::parse_text(&manifest_path, text)?,
    };
    let v1_manifest = match &manifest_file {
        manifest::ManifestFile::Legacy { raw } => Some(raw.clone()),
        _ => None,
    };
    let already_current = matches!(manifest_file, manifest::ManifestFile::Current(_));

    let v2_lock_path = lock::lock_path(env, scope);
    let v1_lock_file = v1_lock_path(env, scope);
    let shared_path = v1_lock_file == v2_lock_path;
    let lock_read = read_bound(&v2_lock_path)?;
    let v2_lock_state = match &lock_read.text {
        None => lock::LockFile::Absent,
        Some(text) => lock::parse_text(&v2_lock_path, text)?,
    };

    let v1_lock = match &v2_lock_state {
        lock::LockFile::Legacy { raw } if shared_path => Some(raw.clone()),
        // A v1-format record sitting at the v2 path of a scope whose v1
        // path is elsewhere: not ours to guess about. Refuse — every other
        // verb refuses it too.
        lock::LockFile::Legacy { .. } => {
            return Err(err(
                scope,
                format!(
                    "a v1-format record sits at the v2 lock path ({}) — move it aside and rerun",
                    v2_lock_path.display()
                ),
            ));
        }
        _ => read_global_v1_lock(scope, &v1_lock_file)?,
    };

    if v1_manifest.is_none() && v1_lock.is_none() {
        if already_current {
            notes.push("already migrated".to_owned());
        }
        return Ok(Migration {
            notes,
            migrated: None,
        });
    }

    // The destination must be empty: a live v2 record is current
    // provenance, and re-importing v1 history over it replaces truth.
    if let lock::LockFile::Current(current) = &v2_lock_state
        && !current.entries.is_empty()
    {
        let leftover = match shared_path {
            true => format!(
                "the remaining v1 leftover is the manifest at {}",
                manifest_path.display()
            ),
            false => format!(
                "remove the stale v1 lock at {} instead",
                v1_lock_file.display()
            ),
        };
        return Err(err(
            scope,
            format!(
                "this scope already has a live v2 install record ({} entries) — refusing to import over it; {leftover}",
                current.entries.len()
            ),
        ));
    }

    let outcome = super::convert(v1_manifest.as_deref(), v1_lock.as_deref())
        .map_err(|message| err(scope, message))?;
    notes.extend(outcome.notes.iter().cloned());

    backup(env, &manifest_path)?;
    backup(env, &v1_lock_file)?;
    let entries = outcome.lock.entries.len();
    execute_migration(
        env,
        scope,
        outcome,
        Destinations {
            manifest_path,
            manifest_pre: manifest_read.pre,
            write_manifest: !already_current,
            v2_lock_path,
            lock_pre: lock_read.pre,
            retire_v1_lock: (!shared_path)
                .then_some(v1_lock_file)
                .filter(|_| v1_lock.is_some()),
            v1_lock_bytes: v1_lock,
        },
    )?;
    Ok(Migration {
        notes,
        migrated: Some(entries),
    })
}

/// Where the migrated records land, with the preconditions bound to the
/// bytes classification read.
struct Destinations {
    manifest_path: PathBuf,
    manifest_pre: Pre,
    write_manifest: bool,
    v2_lock_path: PathBuf,
    lock_pre: Pre,
    /// The separate v1 lock file to retire (global scope only).
    retire_v1_lock: Option<PathBuf>,
    v1_lock_bytes: Option<String>,
}

/// One journaled plan: the journal rolls a failure back whole, the scope
/// lock keeps a concurrent writer out during execution, and any write that
/// landed between classification and here is PlanStale, never a clobber.
fn execute_migration(
    env: &Env,
    scope: &Scope,
    outcome: super::ImportOutcome,
    to: Destinations,
) -> Result<()> {
    let mut ops = Vec::new();
    if to.write_manifest {
        // The destination resolves to either generation's filename, so the
        // plan names the one it will actually write.
        let manifest_name = to
            .manifest_path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| crate::rename::MANIFEST_FILE.to_owned());
        ops.push(PlannedOp {
            description: format!("write the migrated {manifest_name}"),
            op: Op::WriteManifest {
                pre: to.manifest_pre,
                path: to.manifest_path,
                manifest: Box::new(outcome.manifest),
            },
        });
    }
    ops.push(PlannedOp {
        description: "write the migrated install record".into(),
        op: Op::WriteLock {
            pre: to.lock_pre,
            path: to.v2_lock_path,
            lock: Box::new(outcome.lock),
        },
    });
    // The v1 global lock lives in v1's own dir and would re-trigger import
    // forever; a project's shares the v2 path, replaced above.
    if let Some(v1_lock_file) = to.retire_v1_lock {
        ops.push(PlannedOp {
            description: "retire the v1 lock".into(),
            op: Op::Trash {
                pre: Pre::HashIs {
                    hash: crate::hash::hash_bytes(
                        to.v1_lock_bytes.as_deref().unwrap_or_default().as_bytes(),
                    ),
                },
                path: v1_lock_file,
            },
        });
    }
    crate::apply::execute(
        env,
        &Plan {
            scope: scope.clone(),
            ops,
        },
        None,
    )?;
    Ok(())
}

/// The global scope's separate v1 lock file. A file that exists but cannot
/// be read, or is neither a v1 lock nor a current one, is a refusal —
/// treating it as absent would bury a damaged record under a fresh empty
/// lock.
fn read_global_v1_lock(scope: &Scope, path: &std::path::Path) -> Result<Option<String>> {
    let Some(text) = crate::fs::read_if_exists(path)? else {
        return Ok(None);
    };
    if lock::is_v1_text(&text) {
        return Ok(Some(text));
    }
    if matches!(
        lock::parse_text(path, &text),
        Ok(lock::LockFile::Current(_))
    ) {
        return Ok(None);
    }
    Err(err(
        scope,
        format!(
            "{} exists but is neither a v1 lock nor a current one — inspect it; refusing to treat a damaged record as absent",
            path.display()
        ),
    ))
}
