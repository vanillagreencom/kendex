use std::fs;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;

pub mod journal;
mod landing;
mod op;
mod plan;
mod pre;
mod transaction;

pub use op::{Op, Pre, read_git_config};
pub use plan::{Description, Plan, PlannedOp};
use transaction::run_journaled;

/// Filesystem-safe key naming a scope's journal dir and lock file. Keys off
/// the canonical scope so two spellings of one root can never hold two
/// locks (invariant 8 depends on this, not on callers normalizing paths).
pub fn scope_key(scope: &Scope) -> String {
    match scope.canonical() {
        Scope::Global => "global".to_owned(),
        Scope::Project { root } => {
            let text = root.display().to_string();
            let base = root
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "project".to_owned());
            format!("{base}-{}", crate::hash::fnv1a_hex(text.as_bytes()))
        }
    }
}

/// Exclusive writer lock over one scope journal key (invariant 8). Held for
/// the whole journal → mutate → clear window; recovery runs under the same
/// lock.
struct ScopeGuard {
    _file: crate::fs::LockedFile,
}

fn lock_scope(env: &Env, scope: &Scope) -> Result<ScopeGuard> {
    lock_key(env, &scope_key(scope))
}

fn lock_key(env: &Env, key: &str) -> Result<ScopeGuard> {
    let dir = env.scope_locks_dir();
    fs::create_dir_all(&dir).map_err(|e| CoreError::io(&dir, e))?;
    let path = dir.join(format!("{key}.lock"));
    // Only contention is "busy": a filesystem that cannot lock at all must
    // say so, or every launch pass would skip recovery there in silence.
    match crate::fs::LockedFile::try_exclusive(&path) {
        Ok(Some(file)) => Ok(ScopeGuard { _file: file }),
        Ok(None) => Err(CoreError::ScopeBusy { lock: path }),
        Err(error) => Err(CoreError::io(&path, error)),
    }
}

/// Recovery under the scope lock, for callers outside an apply (launch
/// passes). A busy scope has a live writer that will recover it itself.
pub fn recover_locked(env: &Env, scope: &Scope) -> Result<bool> {
    let _guard = lock_scope(env, scope)?;
    recover(env, scope)
}

/// Roll back an interrupted apply, if one left a journal. Returns whether
/// recovery ran. Called under the scope lock on every apply, and at app
/// launch for every known scope.
pub fn recover(env: &Env, scope: &Scope) -> Result<bool> {
    recover_key(env, &scope_key(scope))
}

fn recover_key(env: &Env, key: &str) -> Result<bool> {
    let dir = journal::journal_dir_for(&env.journal_dir(), key);
    if journal::pending(&dir) {
        journal::rollback(&dir)?;
        return Ok(true);
    }
    journal::clear(&dir)?;
    Ok(false)
}

#[derive(Debug)]
pub struct ApplyOutcome {
    pub applied: usize,
    pub recovered_first: bool,
}

/// Execute a plan transactionally. If recovery runs first, the plan
/// predates it and preconditions do the talking.
pub fn execute(env: &Env, plan: &Plan) -> Result<ApplyOutcome> {
    let _guard = lock_scope(env, &plan.scope)?;
    let recovered_first = recover(env, &plan.scope)?;
    let applied = run_journaled(env, &plan.ops, &scope_key(&plan.scope))?;
    // The scope just changed; a drift snapshot describing the old state
    // would send the next session chasing drift that no longer exists.
    // Invalidation is the cheap honest move: the check reads "not yet
    // evaluated" and its background job re-derives. Verbs that already do
    // the deep work re-record right after this returns. Best-effort — a
    // failure here leaves a stale snapshot, which the refs-state check and
    // the next deep pass both correct.
    if !plan.ops.is_empty() {
        let _ = crate::drift::snapshot::invalidate(env, &plan.scope);
    }
    Ok(ApplyOutcome {
        applied,
        recovered_first,
    })
}

#[cfg(test)]
mod tests;
