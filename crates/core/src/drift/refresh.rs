//! The detached background job the session check spawns: fetch every stale
//! mirror (TTL from [`super::stamps`]), then re-derive the drift snapshot
//! so the next session reads verdicts, not guesses, and finish the plan
//! over declarations sitting on unrecorded files where the check's budget
//! cut it short ([`super::copies`]). Runs with no stdio and is never
//! waited on; everything it learns lands in stamps, snapshots and memos.

use std::time::Duration;

use crate::env::Env;
use crate::error::CoreError;
use crate::model::Scope;
use crate::remote::store;

/// The background fetch may take longer than an interactive wait, but it
/// still has to finish — a hung link is a failure stamp, not a hung job.
pub(crate) const FETCH_DEADLINE: Duration = Duration::from_secs(60);

/// Fetch stale mirrors for these scopes and re-derive their snapshots.
/// Returns notes for a caller that has a terminal; the detached job drops
/// them. A busy mirror lock is neither success nor failure — skipped, its
/// stamp untouched, for the next pass to pick up.
pub fn refresh_stale(env: &Env, scopes: &[Scope]) -> Vec<String> {
    let background = env
        .clone()
        .with_source_cache_wait(crate::env::SourceCacheWait::Background);
    let env = &background;
    let now = crate::clock::unix_now();
    let mut notes = Vec::new();
    let mut fetched: std::collections::BTreeSet<String> = Default::default();

    for scope in scopes {
        let Ok(crate::manifest::ManifestFile::Current(manifest)) =
            crate::manifest::load(&crate::manifest::manifest_path(env, scope))
        else {
            continue;
        };
        let remotes = manifest
            .sources
            .values()
            .any(|decl| decl.enabled && decl.repo.is_some());
        let mut touched = false;
        for decl in manifest.sources.values() {
            let Some(repo) = decl.repo.as_deref().filter(|_| decl.enabled) else {
                continue;
            };
            let url = crate::remote::clone_url(env, repo);
            let key = crate::remote::cache_key(env, repo);
            if fetched.contains(&key) {
                touched = true;
                continue;
            }
            if !super::stamps::load(env, &key).is_stale(now) {
                continue;
            }
            let mirror = store::mirror_dir(env, &key);
            let guard = match store::lock_repo(env, &key) {
                Ok(guard) => guard,
                Err(CoreError::CacheBusy { .. }) => {
                    notes.push(format!("{repo}: busy, skipped"));
                    continue;
                }
                Err(error) => {
                    notes.push(format!("{repo}: {error}"));
                    continue;
                }
            };
            let result = store::ensure_mirror(&mirror, &url)
                .and_then(|()| store::fetch_within(&mirror, FETCH_DEADLINE));
            let stamped = match &result {
                Ok(()) => super::stamps::record_success(
                    env,
                    &key,
                    super::stamps::refs_state(&mirror),
                    crate::clock::unix_now(),
                ),
                Err(error) => super::stamps::record_failure(
                    env,
                    &key,
                    &error.to_string(),
                    crate::clock::unix_now(),
                ),
            };
            if let Err(error) = stamped {
                notes.push(format!("{repo}: stamp not written ({error})"));
            }
            if let Err(error) = result {
                notes.push(format!("{repo}: fetch failed ({error})"));
            }
            drop(guard);
            fetched.insert(key);
            touched = true;
        }
        // The deep work is legal here: after fetching, re-derive the
        // snapshot so the next session check reads verdicts. Also derived
        // when the scope has never been evaluated at all. A scope with no
        // remote source has no verdict a fetch could move, and the check
        // reads its absent snapshot as nothing to say.
        if remotes
            && (touched
                || !matches!(
                    super::snapshot::load(env, scope),
                    super::snapshot::SnapshotFile::Current(_)
                ))
            && let Err(error) = super::snapshot::record(env, scope)
        {
            notes.push(format!("{}: snapshot not derived ({error})", scope.label()));
        }
        // The other deep read the check owes: the plan over declarations
        // sitting on files no record accounts for, where nothing has
        // judged them under their current state — the plan a check's
        // deadline cut short. Unbudgeted here, since nothing waits on
        // this job.
        if let Err(error) = super::copies::derive(env, scope) {
            notes.push(format!(
                "{}: unrecorded copies not compared ({error})",
                scope.label()
            ));
        }
    }
    notes
}
