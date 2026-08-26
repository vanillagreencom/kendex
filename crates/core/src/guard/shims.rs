//! Reading what is armed, off the shim files themselves.
//!
//! Normally the package's own installer answers this and kendex relays it,
//! so there is one definition of "armed". These reads are for the two cases
//! where that installer cannot: a package removed before its shims were
//! disarmed, and the moment mid-migration when the shims are written but
//! git does not read them yet.

use std::path::Path;

use crate::error::Result;

use super::LANES;

/// The helper the package's installer writes, and the marker it puts on the
/// delegating line — the two ways a repository can still be armed after the
/// package that armed it is gone.
pub(super) const HELPER: &str = "kendex-guards";
const SENTINEL: &str = "# kendex-guards-hook";

/// A line naming shims left behind with no package to run them, or `None`
/// where neither hooks directory holds any.
///
/// Read off the shim files, since the installer that would otherwise answer
/// is exactly what is missing. Both directories are looked at, and they are
/// judged differently. What git actually reads (`rev-parse --git-path
/// hooks`) is where a shim blocks commits right now. The repository's
/// default directory is where a shim sits dormant behind a redirect — not
/// blocking anything yet, and live the moment the redirect goes, which is a
/// different sentence and needs saying too.
pub(super) fn stale_shims(repo: &super::Repo) -> Result<Option<String>> {
    let live = repo.effective_hooks_dir()?;
    let default = repo.default_hooks_dir();
    let mut said = Vec::new();
    if let Some(found) = shims_in(&live)? {
        said.push(format!(
            "{} carries the package's shims ({found}) with nothing here to run them — commits are blocked until they go",
            live.display()
        ));
    }
    // Named separately only when it is a different directory: otherwise the
    // line above already covers it.
    if live != default
        && let Some(found) = shims_in(&default)?
    {
        said.push(format!(
                "{} carries dormant shims ({found}) git does not read while core.hooksPath redirects it — they block commits the moment it goes",
                default.display()
            ));
    }
    Ok((!said.is_empty()).then(|| said.join("; ")))
}

/// The package's shims present in one directory, named — counting only
/// what git would actually run.
///
/// Two things this deliberately does not count. The helper on its own is
/// inert: git runs hooks by name, and nothing is named `kendex-guards`, so
/// a leftover helper blocks no commit. And a file merely *containing* the
/// sentinel is not a hook — a comment quoting it, a README, a test fixture
/// — so the line has to be a delegating line: the sentinel ending a line
/// that invokes the helper. A hook without its execute bit is skipped by
/// git in silence, so it is not blocking anything either.
fn shims_in(hooks: &Path) -> Result<Option<String>> {
    let mut found = Vec::new();
    for lane in LANES {
        let path = hooks.join(lane);
        if delegates(&path)? {
            found.push(lane.to_owned());
        }
    }
    // The helper is named only alongside a hook that reaches for it, where
    // it is the thing a reader has to remove as well.
    if !found.is_empty() && hooks.join(HELPER).exists() {
        found.push(HELPER.to_owned());
    }

    Ok((!found.is_empty()).then(|| found.join(", ")))
}

/// Whether this file is a hook git will run that hands off to the package.
fn delegates(path: &Path) -> Result<bool> {
    if !is_executable(path) {
        return Ok(false);
    }
    let Some(text) = crate::fs::read_if_exists(path)? else {
        return Ok(false);
    };
    Ok(text.lines().any(is_delegating_line))
}

/// Whether one line hands off to the helper, rather than talking about it.
///
/// Three things have to hold together. The line is in command position — a
/// comment mentioning the marker, a README line quoted into a hook, a
/// disabled line someone commented out, are all talk. It names the helper,
/// which is what it hands off to. And the marker ends it, which is the
/// shape the installer writes and the shape it rewrites when it repairs.
/// Any one of the three alone is satisfied by prose.
fn is_delegating_line(line: &str) -> bool {
    let line = line.trim();
    !line.starts_with('#') && line.ends_with(SENTINEL) && line.contains(HELPER)
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// What a hooks directory is missing to count as armed, or `None` when it
/// carries the helper and both lanes delegate.
pub(super) fn missing_shims(hooks: &Path) -> Result<Option<String>> {
    let mut missing = Vec::new();
    // Executable, not merely present: the delegating line tests `-x` before
    // it hands off and blocks the commit when that fails, so a helper git
    // cannot run is a repository where every commit fails — the opposite of
    // armed, however present the file is.
    if !is_executable(&hooks.join(HELPER)) {
        missing.push(HELPER.to_owned());
    }
    for lane in LANES {
        if !delegates(&hooks.join(lane))? {
            missing.push(lane.to_owned());
        }
    }
    Ok((!missing.is_empty()).then(|| format!("missing {}", missing.join(", "))))
}
