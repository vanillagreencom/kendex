//! Why the takeback refuses instead of proceeding. It guards the one
//! ownership invariant left: kendex only ever removes what it provably
//! wrote, and a refusal is the whole response rather than a partial
//! mutation.

use std::collections::BTreeSet;

use crate::error::{CoreError, Result};

use super::{Receipt, Repo, err};

/// Uninstall-time refusal: files kendex didn't write found in the owned
/// directory. Unsetting `core.hooksPath` around a surviving user hook
/// would silently disable it, so partial removal refuses instead.
pub(super) fn check_uninstall(repo: &Repo, receipt: &Receipt) -> Result<()> {
    let hooks_dir = repo.hooks_dir()?;
    if !hooks_dir.exists() {
        return Ok(());
    }
    let recorded: BTreeSet<&str> = receipt.files.iter().map(String::as_str).collect();
    let entries = std::fs::read_dir(&hooks_dir).map_err(|e| CoreError::io(&hooks_dir, e))?;
    let mut foreign = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| CoreError::io(&hooks_dir, e))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !recorded.contains(name.as_str()) {
            foreign.push(name);
        }
    }
    if !foreign.is_empty() {
        return Err(err(format!(
            "{} holds file(s) kendex did not write ({}) — removing around them would silently disable them the moment core.hooksPath is unset; move them into git's own hooks directory (or delete them) and rerun",
            hooks_dir.display(),
            foreign.join(", ")
        )));
    }
    Ok(())
}
