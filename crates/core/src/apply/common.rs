//! Common-state applies: mutations that live in a repository's git common
//! dir (the shared hooks directory, the repo's config), locked and
//! journaled per common dir rather than per worktree scope — two linked
//! worktrees share the state, so they must share the lock and the journal.

use std::path::Path;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;

use super::{ApplyOutcome, PlannedOp, lock_key, lock_scope, recover_key, run_journaled};

const KEY_PREFIX: &str = "git-common-";

/// Filesystem-safe key naming a repository's common-dir lock and journal.
/// Hook state is repository-common state: two linked worktrees share one
/// hooks directory, and a lock keyed per worktree would let them mutate it
/// under different locks. The repository's directory name rides along so
/// a launch message about this key names something a person recognizes.
pub fn common_key(common_dir: &Path) -> String {
    let canonical = common_dir
        .canonicalize()
        .unwrap_or_else(|_| common_dir.to_path_buf());
    let text = canonical.display().to_string();
    let base = canonical
        .parent()
        .and_then(Path::file_name)
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "repo".to_owned());
    format!(
        "{KEY_PREFIX}{base}-{}",
        crate::hash::fnv1a_hex(text.as_bytes())
    )
}

/// Execute a mutation of repository-common state. Lock order is fixed —
/// the scope lock first, then the common-dir lock — and the plan is built
/// by `build` only once both are held and the common journal is
/// recovered: every refusal and precondition it observes is observed
/// under the lock, so no other writer can change the directory's shape
/// between the check and the write. `build` returns the ops plus whatever
/// the caller wants back beside the outcome.
pub fn execute_common<T>(
    env: &Env,
    scope: &Scope,
    common_dir: &Path,
    build: impl FnOnce() -> Result<(Vec<PlannedOp>, T)>,
) -> Result<(ApplyOutcome, T)> {
    let _scope_guard = lock_scope(env, scope)?;
    let key = common_key(common_dir);
    let _common_guard = lock_key(env, &key)?;
    let recovered_first = recover_key(env, &key)?;
    let (ops, extra) = build()?;
    let applied = run_journaled(env, &ops, &key, None)?;
    Ok((
        ApplyOutcome {
            applied,
            recovered_first,
            // Common state is machine-wide and writes no scope manifest;
            // the caller that needs one writes it through `execute`.
            manifest_base: super::manifest_base(env, scope),
        },
        extra,
    ))
}

/// Recover every interrupted common-state apply this machine's journal
/// dir records — the launch pass, which otherwise only knows scopes. Each
/// key reports whether it recovered, or why it could not (a busy key has
/// a live writer that recovers it itself). No journal dir yet means no
/// apply ever ran; any other failure to list it is an error, because a
/// listing that cannot be read is not a listing that is empty.
pub fn recover_common_journals(env: &Env) -> Result<Vec<(String, Result<bool>)>> {
    let base = env.journal_dir();
    let entries = match std::fs::read_dir(&base) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(CoreError::io(&base, error)),
    };
    let mut keys = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| CoreError::io(&base, error))?;
        if let Ok(name) = entry.file_name().into_string()
            && name.starts_with(KEY_PREFIX)
        {
            keys.push(name);
        }
    }
    keys.sort();
    Ok(keys
        .into_iter()
        .map(|key| {
            let result = lock_key(env, &key).and_then(|_guard| recover_key(env, &key));
            (key, result)
        })
        .collect())
}
