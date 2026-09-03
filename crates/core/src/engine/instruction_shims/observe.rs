//! Reading where each shim stands: which `AGENTS.md` files git tracks,
//! what sits beside each, and what Gemini's settings already name.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use super::{AGENTS_FILE, CLAUDE_SHIM, CLAUDE_SHIM_FILE, OLD_LINK, ShimStanding, ShimState};
use crate::configedit::ConfigEdit;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{HarnessId, Scope};

/// Every `AGENTS.md` the project's repository tracks under the root, the
/// root's own first. Asked of git, so a directory git does not track is
/// never walked; a project outside any repository has only its root file
/// to consider. Listed and on disk as a regular file: a tracked file
/// deleted from the working tree, or a link, has no shim to serve.
///
/// git's refusal to answer is read for the one reason this pass expects —
/// no repository here — and every other failure is the pass's own error:
/// a repository git will not read is not a project with one file in it.
pub(super) fn agents_files(root: &Path) -> Result<Vec<PathBuf>> {
    let nested = format!("*/{AGENTS_FILE}");
    let output = crate::guard::english(crate::process::Hardened::git(
        &["ls-files", "-z", "--", AGENTS_FILE, &nested],
        Some(root),
    ))
    .run()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("not a git repository") {
            let root_file = root.join(AGENTS_FILE);
            return Ok(match regular_file(&root_file)? {
                true => vec![root_file],
                false => Vec::new(),
            });
        }
        return Err(CoreError::GitFailed {
            command: "git ls-files".to_owned(),
            stderr: stderr.trim().to_owned(),
        });
    }
    let mut found = Vec::new();
    for entry in output.stdout.split(|byte| *byte == 0) {
        if entry.is_empty() {
            continue;
        }
        let relative = crate::guard::path_from(entry.to_vec(), "ls-files")?;
        // The pathspec above already selects the name; asked again here
        // so what counts as an instruction file is decided by this pass
        // and not by git's glob rules.
        if relative.file_name() != Some(OsStr::new(AGENTS_FILE)) {
            continue;
        }
        let path = root.join(relative);
        if regular_file(&path)? {
            found.push(path);
        }
    }
    found.sort();
    Ok(found)
}

/// Whether a regular file sits at the path, no link followed. Absence is
/// `false`; a path that cannot be stat'ed is an error, since calling it
/// absent would silently drop the shim it owes.
fn regular_file(path: &Path) -> Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) => Ok(meta.is_file()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(CoreError::io(path, error)),
    }
}

fn relative_name(root: &Path, path: &Path) -> String {
    let relative = path.strip_prefix(root).unwrap_or(path);
    crate::paths::slashed(relative)
}

pub(super) fn claude_standing(root: &Path, agents_file: &Path) -> Result<ShimStanding> {
    let path = agents_file.parent().unwrap_or(root).join(CLAUDE_SHIM_FILE);
    let name = relative_name(root, &path);
    let state = match std::fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => ShimState::Missing,
        Err(error) => ShimState::Refused(uncomparable(&name, &CoreError::io(&path, error))),
        Ok(meta) if meta.is_symlink() => ShimState::Symlinked,
        Ok(meta) if !meta.is_file() => ShimState::Refused(format!(
            "{} is not a regular file — move it aside, then apply again",
            crate::names::shown(&name)
        )),
        Ok(_) => match std::fs::read(&path) {
            Ok(bytes) if bytes == CLAUDE_SHIM.as_bytes() => ShimState::InSync,
            Ok(_) => ShimState::Foreign,
            Err(error) => ShimState::Refused(uncomparable(&name, &CoreError::io(&path, error))),
        },
    };
    Ok(ShimStanding {
        path,
        name,
        harness: HarnessId::Claude,
        state,
    })
}

/// A shim kendex cannot read is reported uncompared (invariant 12), never
/// as passing, and never at the cost of the whole scope.
fn uncomparable(name: &str, error: &CoreError) -> String {
    format!(
        "{} cannot be compared ({error}) — fix its permissions or remove it",
        crate::names::shown(name)
    )
}

/// The retired convention's link, where it still points at the root
/// `AGENTS.md`. Anything else at that path — a plain file, a link
/// elsewhere — is the person's and is not reported.
pub(super) fn old_link(root: &Path, agents: &[PathBuf]) -> Result<Option<ShimStanding>> {
    let root_agents = root.join(AGENTS_FILE);
    if !agents.iter().any(|path| path == &root_agents) {
        return Ok(None);
    }
    let link = root.join(OLD_LINK);
    if !link.is_symlink() {
        return Ok(None);
    }
    let Ok(target) = crate::paths::canonical(&link) else {
        return Ok(None);
    };
    let root_agents = crate::paths::canonical(&root_agents)
        .map_err(|error| CoreError::io(&root_agents, error))?;
    if target != root_agents {
        return Ok(None);
    }
    Ok(Some(ShimStanding {
        name: relative_name(root, &link),
        path: link,
        harness: HarnessId::Claude,
        state: ShimState::OldLink,
    }))
}

/// The edit the Gemini shim is: `context.fileName` names `AGENTS.md`.
pub(super) fn gemini_edit() -> ConfigEdit {
    ConfigEdit::GeminiAddContextFile {
        name: AGENTS_FILE.to_owned(),
    }
}

pub(super) fn gemini_standing(env: &Env, scope: &Scope, root: &Path) -> Result<ShimStanding> {
    let path = crate::harness::gemini::settings::settings_file(env, scope);
    let name = relative_name(root, &path);
    let standing = |state| ShimStanding {
        path: path.clone(),
        name: name.clone(),
        harness: HarnessId::Gemini,
        state,
    };
    // Through a link, if one sits there: a person's own link at a settings
    // file is edited in place (invariant 6). A directory is nowhere a
    // setting can go.
    if path.exists() && !path.is_file() {
        return Ok(standing(ShimState::Refused(format!(
            "{} is not a regular file — move it aside, then apply again",
            crate::names::shown(&name)
        ))));
    }
    if let Some(reason) = crate::harness::gemini::settings::read(&path).unmanageable() {
        return Ok(standing(ShimState::Refused(format!(
            "{} was not edited: {reason}",
            crate::names::shown(&name)
        ))));
    }
    let current = match crate::fs::read_if_exists(&path) {
        Ok(current) => current,
        Err(error) => return Ok(standing(ShimState::Refused(uncomparable(&name, &error)))),
    };
    // A file that will not parse is refused, not rewritten (invariant 10):
    // the same idempotency check every registration makes.
    let state = match gemini_edit().apply(current.as_deref().unwrap_or_default()) {
        Ok(updated) if Some(updated.as_str()) == current.as_deref() => ShimState::InSync,
        Ok(_) if current.is_none() => ShimState::Missing,
        Ok(_) => ShimState::Stale,
        Err(message) => ShimState::Refused(format!(
            "{} could not be edited: {message}",
            crate::names::shown(&name)
        )),
    };
    Ok(standing(state))
}
