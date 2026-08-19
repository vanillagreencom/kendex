//! `vstack cache-refresh`: bring every remote source cache this scope's locks
//! name up to date, and account for the ones it could not.
//!
//! Silence used to be this command's only output, whatever it had failed to
//! do — a source it could not even map to a remote simply never appeared, and
//! it exited 0 on a state `check` and `verify` both exited 1 on. Now every
//! problem it comes back with is named, and one no re-run can clear is a
//! nonzero exit.

use crate::config;
use crate::scope::ScopeFilter;
use anyhow::Result;

pub fn run(scope: ScopeFilter) -> Result<()> {
    let mut unfixable = 0usize;
    for &global in scope.globals() {
        let lock = config::LockFile::load(&config::lock_file_path(global)).unwrap_or_default();
        // The detached refresher, and the ONE caller for which a guard held
        // elsewhere is a success: somebody else is already doing this job.
        let problems = config::refresh_remote_caches_older_than(
            &lock,
            Some(config::REMOTE_CACHE_TTL),
            config::FetchBound::BACKGROUND,
        );
        for problem in problems {
            // A transient failure is still exit 0: it is reported, and the
            // next run fixes it.
            if problem.kind.is_persistent() {
                unfixable += 1;
            }
            eprintln!(
                "  {}: {}",
                crate::display::scrub_source_credentials(&problem.source),
                problem.kind.describe()
            );
        }
    }
    if unfixable > 0 {
        anyhow::bail!("{unfixable} cached source(s) cannot be refreshed as recorded — see above");
    }
    Ok(())
}
