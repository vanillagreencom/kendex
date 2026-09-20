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

/// The locks that make writes to one or more scopes one transaction at a
/// time. Machine-file locks come first and are de-duplicated, so linked
/// roots that share a cache cannot overwrite or roll back each other's
/// rows. Scope locks keep each journal single-writer as before.
pub struct WriteGuards {
    machine: Vec<crate::fs::LockedFile>,
    _scope: Vec<ScopeGuard>,
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

/// Lock and recover every scope before a writer reads its install record.
/// The machine-file lock spans that read through the caller's last save.
/// One call may name linked roots that share the same cache; their shared
/// lock is acquired once.
pub fn lock_scopes_for_write(env: &Env, scopes: &[Scope]) -> Result<WriteGuards> {
    begin_writes(env, scopes).map(|(guards, _)| guards)
}

fn begin_writes(env: &Env, scopes: &[Scope]) -> Result<(WriteGuards, Vec<bool>)> {
    let dir = env.scope_locks_dir();
    fs::create_dir_all(&dir).map_err(|error| CoreError::io(&dir, error))?;

    // Sort every class before taking it. A command that writes several
    // scopes then has the same lock order as another such command.
    let mut machine_paths: Vec<_> = scopes
        .iter()
        .map(|scope| machine_lock_path(env, scope))
        .collect();
    machine_paths.sort();
    machine_paths.dedup();
    let machine = machine_paths
        .iter()
        .map(|path| {
            crate::fs::LockedFile::exclusive(path).map_err(|error| CoreError::io(path, error))
        })
        .collect::<Result<Vec<_>>>()?;

    let mut scope_keys: Vec<_> = scopes.iter().map(scope_key).collect();
    scope_keys.sort();
    scope_keys.dedup();
    let scope = scope_keys
        .iter()
        .map(|key| lock_key(env, key))
        .collect::<Result<Vec<_>>>()?;
    let recovered = scopes
        .iter()
        .map(|scope| recover_key(env, &scope_key(scope)))
        .collect::<Result<Vec<_>>>()?;
    Ok((
        WriteGuards {
            machine,
            _scope: scope,
        },
        recovered,
    ))
}

/// The lock-file identity for the machine half a scope reaches. Resolving
/// the data path before hashing it makes two linked `.cache` spellings one
/// writer lock even before the data file itself exists.
fn machine_lock_path(env: &Env, scope: &Scope) -> std::path::PathBuf {
    let lock = crate::lock::lock_path(env, scope);
    let machine = crate::paths::absolute(&crate::lock::machine_path(&lock));
    let key = crate::hash::fnv1a_hex(crate::paths::slashed(&machine).as_bytes());
    env.scope_locks_dir().join(format!("machine-{key}.lock"))
}

/// Recovery under the scope lock, for callers outside an apply (launch
/// passes). A busy scope has a live writer that will recover it itself.
pub fn recover_locked(env: &Env, scope: &Scope) -> Result<bool> {
    recover(env, scope)
}

/// Roll back an interrupted apply, if one left a journal. Returns whether
/// recovery ran. The machine and scope locks cover the whole rollback, so
/// restoring a shared machine file cannot erase another root's write.
pub fn recover(env: &Env, scope: &Scope) -> Result<bool> {
    let (_guards, recovered) = begin_writes(env, std::slice::from_ref(scope))?;
    Ok(recovered[0])
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
    execute_closing(env, plan, Close::Clear).map(|(outcome, _guards)| outcome)
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
    machine: crate::fs::LockedFile,
    pub applied: usize,
}

/// Execute a plan transactionally and hold its journal; see [`Held`].
pub fn execute_held(env: &Env, plan: &Plan) -> Result<Held> {
    let (outcome, mut guards) = execute_closing(env, plan, Close::Hold)?;
    let Some(machine) = guards.machine.pop() else {
        return Err(CoreError::io(
            env.scope_locks_dir(),
            std::io::Error::other("the apply acquired no machine-file lock"),
        ));
    };
    // The held journal remains protected by the machine lock. Release the
    // scope lock so an abort can still report a competing scope writer.
    drop(guards);
    Ok(Held {
        scope: plan.scope.clone(),
        machine,
        applied: outcome.applied,
    })
}

impl Held {
    /// Make the writes final.
    pub fn keep(self, env: &Env) -> Result<()> {
        let _machine = self.machine;
        let _guard = lock_scope(env, &self.scope)?;
        journal::clear(&journal::journal_dir_for(
            &env.journal_dir(),
            &scope_key(&self.scope),
        ))
    }

    /// Roll the writes back.
    pub fn abort(self, env: &Env) -> Result<()> {
        let _machine = self.machine;
        let _guard = lock_scope(env, &self.scope)?;
        recover_key(env, &scope_key(&self.scope)).map(|_| ())
    }
}

fn execute_closing(env: &Env, plan: &Plan, close: Close) -> Result<(ApplyOutcome, WriteGuards)> {
    let (guards, recovered) = begin_writes(env, std::slice::from_ref(&plan.scope))?;
    let recovered_first = recovered[0];
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
    Ok((
        ApplyOutcome {
            applied,
            recovered_first,
        },
        guards,
    ))
}

#[cfg(test)]
mod tests;
