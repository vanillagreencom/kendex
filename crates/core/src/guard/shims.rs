//! Reading what is armed, off the shim files themselves.
//!
//! Normally the package's own installer answers this and kendex relays it,
//! so there is one definition of "armed". These reads are for the two cases
//! where that installer cannot: a package removed before its shims were
//! disarmed, and the moment mid-migration when the shims are written but
//! git does not read them yet.

use std::path::Path;

use crate::error::Result;

use super::{LANES, SKILL};

/// The helper the package's installer writes, and the marker it puts on the
/// delegating line — the two ways a repository can still be armed after the
/// package that armed it is gone.
const HELPER: &str = "kendex-guards";
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
pub(super) fn stale_shims(repo: &crate::githooks::Repo) -> Result<Option<String>> {
    let live = crate::githooks::effective_hooks_dir(&repo.worktree)?;
    let default = crate::githooks::default_hooks_dir(repo);
    let mut said = Vec::new();
    if let Some(found) = shims_in(&live)? {
        said.push(format!(
            "{} still carries the package's shims ({found}) with no {SKILL} skill to run them — every commit here is blocked until they are removed or the package is reinstalled",
            live.display()
        ));
    }
    // Named separately only when it is a different directory: otherwise the
    // line above already covers it.
    if live != default
        && let Some(found) = shims_in(&default)?
    {
        said.push(format!(
                "{} carries dormant shims ({found}) that git does not read while core.hooksPath redirects it — they block every commit the moment that redirect goes",
                default.display()
            ));
    }
    Ok((!said.is_empty()).then(|| said.join("; ")))
}

/// The package's shims present in one directory, named.
fn shims_in(hooks: &Path) -> Result<Option<String>> {
    let mut found = Vec::new();
    if hooks.join(HELPER).exists() {
        found.push(HELPER.to_owned());
    }
    for lane in LANES {
        let path = hooks.join(lane);
        if crate::fs::read_if_exists(&path)?.is_some_and(|text| text.contains(SENTINEL)) {
            found.push(lane.to_owned());
        }
    }
    Ok((!found.is_empty()).then(|| found.join(", ")))
}

/// What a hooks directory is missing to count as armed, or `None` when it
/// carries the helper and both marked lanes.
pub(super) fn missing_shims(hooks: &Path) -> Result<Option<String>> {
    let mut missing = Vec::new();
    if !hooks.join(HELPER).exists() {
        missing.push(HELPER.to_owned());
    }
    for lane in LANES {
        let path = hooks.join(lane);
        if !crate::fs::read_if_exists(&path)?.is_some_and(|text| text.contains(SENTINEL)) {
            missing.push(lane.to_owned());
        }
    }
    Ok((!missing.is_empty()).then(|| format!("missing {}", missing.join(", "))))
}
