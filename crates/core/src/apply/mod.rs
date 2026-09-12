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
pub(crate) use plan::ReadCheck;
pub use plan::{Description, Plan, PlannedOp};
use transaction::{Close, run_journaled};

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
pub struct ScopeGuard {
    _file: crate::fs::LockedFile,
}

/// Hold the scope writer lock across a carrier update and its record write.
pub fn lock_scope(env: &Env, scope: &Scope) -> Result<ScopeGuard> {
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
    execute_closing(env, plan, Close::Clear)
}

/// A plan applied whose writes are not final yet.
///
/// The journal stays pending, so the writes can still be rolled back by
/// [`Held::abort`] or made final by [`Held::keep`]. For a write that is
/// only the preparation for a second plan whose refusal can only be
/// judged once the bytes are on disk — a template's copies into the local
/// slot, which the render that declares them then reads — so a refusal
/// there can take the preparation back with it.
///
/// A held apply that is neither kept nor aborted is rolled back by the
/// next recovery on its scope, which every apply and the app's launch pass
/// run: the writes are only as durable as the process holding this.
#[must_use = "a held apply is rolled back by the next apply on its scope unless it is kept"]
pub struct Held {
    scope: Scope,
    pub applied: usize,
}

/// Execute a plan transactionally and hold its journal; see [`Held`].
pub fn execute_held(env: &Env, plan: &Plan) -> Result<Held> {
    let outcome = execute_closing(env, plan, Close::Hold)?;
    Ok(Held {
        scope: plan.scope.clone(),
        applied: outcome.applied,
    })
}

impl Held {
    /// Make the writes final.
    pub fn keep(self, env: &Env) -> Result<()> {
        let _guard = lock_scope(env, &self.scope)?;
        journal::clear(&journal::journal_dir_for(
            &env.journal_dir(),
            &scope_key(&self.scope),
        ))
    }

    /// Roll the writes back.
    pub fn abort(self, env: &Env) -> Result<()> {
        recover_locked(env, &self.scope).map(|_| ())
    }
}

fn execute_closing(env: &Env, plan: &Plan, close: Close) -> Result<ApplyOutcome> {
    let _guard = lock_scope(env, &plan.scope)?;
    let recovered_first = recover(env, &plan.scope)?;
    let applied = run_journaled(env, &plan.ops, &scope_key(&plan.scope), &plan.reads, close)?;
    // The scope just changed; a drift snapshot describing the old state
    // would send the next session chasing drift that is not there.
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
