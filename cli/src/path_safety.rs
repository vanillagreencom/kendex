use anyhow::{Context, Result, bail};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Path-safety validation for any code path that joins an item name into a
/// filesystem path. Removal must stay on this check alone: an item named after
/// a later-reserved word may have been installed by a previous release, and
/// deleting it has to keep working.
pub(crate) fn validate_item_name(name: &str) -> Result<()> {
    if name.is_empty() {
        bail!("item name must not be empty");
    }
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        bail!("item name must not be empty");
    };
    if !first.is_ascii_alphanumeric() {
        bail!("item name {name:?} must start with an ASCII letter or digit");
    }
    if !chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')) {
        bail!("item name {name:?} must contain only ASCII letters, digits, '.', '_', or '-'");
    }
    Ok(())
}

/// Install/add-time validation: path safety plus the reserved shared key.
/// Only paths that create or regenerate an install reject `all`.
pub(crate) fn validate_new_item_name(name: &str) -> Result<()> {
    validate_item_name(name)?;
    if name.eq_ignore_ascii_case(crate::project_config::SHARED_INSTRUCTIONS_KEY) {
        bail!(
            "item name {name:?} is reserved: `all` is the shared key in \
             [agent-launch-instructions], [agent-additional-instructions], and \
             [skill-instructions] that applies to every agent/skill"
        );
    }
    Ok(())
}

/// Write a generated file without following a symlink in the final path
/// component. Existing symlinks are rejected; normal files are replaced via a
/// same-directory temporary file and rename.
pub(crate) fn write_file_no_follow(path: &Path, contents: impl AsRef<[u8]>) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating parent directory {}", parent.display()))?;
    }
    ensure_file_write_target_safe(path)?;

    let tmp = temp_sibling_path(path)?;
    let write_result = (|| -> Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .with_context(|| format!("creating temporary file {}", tmp.display()))?;
        file.write_all(contents.as_ref())
            .with_context(|| format!("writing temporary file {}", tmp.display()))?;
        file.sync_all()
            .with_context(|| format!("syncing temporary file {}", tmp.display()))?;
        std::fs::rename(&tmp, path)
            .with_context(|| format!("renaming {} to {}", tmp.display(), path.display()))?;
        Ok(())
    })();

    if write_result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    write_result
}

/// `git rev-parse --git-common-dir` for `dir`, canonicalized. `None` when `dir`
/// is not inside a Git repository, when git is unavailable, or when the answer
/// cannot be resolved — every one of which must fail closed at the call site.
pub(crate) fn git_common_dir(dir: &Path) -> Option<PathBuf> {
    let output = std::process::Command::new("git")
        .args(["-C", dir.to_str()?, "rev-parse", "--git-common-dir"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let raw = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if raw.is_empty() {
        return None;
    }
    // `--git-common-dir` is relative to the queried directory unless git is new
    // enough to have been asked for an absolute path, so resolve it against
    // `dir` rather than the process cwd.
    let reported = Path::new(&raw);
    let absolute = if reported.is_absolute() {
        reported.to_path_buf()
    } else {
        dir.join(reported)
    };
    absolute.canonicalize().ok()
}

/// Repository identity of the working tree physically containing `dir`, from
/// a single `git rev-parse` invocation: `(--git-common-dir, --show-toplevel)`,
/// both canonicalized. `None` when `dir` is not inside a working tree, when
/// git is unavailable, or when either answer cannot be resolved — callers
/// must fail closed.
pub(crate) fn git_repo_identity(dir: &Path) -> Option<(PathBuf, PathBuf)> {
    let output = std::process::Command::new("git")
        .args([
            "-C",
            dir.to_str()?,
            "rev-parse",
            "--git-common-dir",
            "--show-toplevel",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut lines = stdout.lines();
    let common_raw = lines.next()?.trim();
    let toplevel_raw = lines.next()?.trim();
    if common_raw.is_empty() || toplevel_raw.is_empty() {
        return None;
    }
    // `--git-common-dir` may be reported relative to the queried directory;
    // resolve it against `dir` rather than the process cwd.
    let common_reported = Path::new(common_raw);
    let common_absolute = if common_reported.is_absolute() {
        common_reported.to_path_buf()
    } else {
        dir.join(common_reported)
    };
    let common = common_absolute.canonicalize().ok()?;
    let toplevel = Path::new(toplevel_raw).canonicalize().ok()?;
    Some((common, toplevel))
}

/// Positive proof that `target` lives in a working tree of the SAME repository
/// as `project_root` — both resolve to one `--git-common-dir`.
///
/// This is not a relaxation of the containment boundary; it answers a different
/// and stronger question. Lexical containment asks "is this path under the
/// project directory", which cannot tell another checkout of the repository the
/// operator is already working in from an arbitrary directory elsewhere on
/// disk. vstack's own `worktree` skill provisions the first case: every issue
/// worktree gets a `.agents` symlink into the main checkout so a ~100 MB harness
/// library is shared rather than copied per branch (vstack#886). Refusing that
/// made refresh unusable from any worktree.
///
/// Everything else still fails closed. A target that is not a repository has no
/// common dir; a target in a DIFFERENT repository has a different one.
pub(crate) fn is_same_repository_worktree(project_root: &Path, target: &Path) -> bool {
    // `git -C` needs a directory. `target` is normally the canonical
    // `.agents`/`.agents/skills` directory, but probe its parent if it is not.
    let probe = if target.is_dir() {
        target
    } else {
        match target.parent() {
            Some(parent) => parent,
            None => return false,
        }
    };
    match (git_common_dir(project_root), git_common_dir(probe)) {
        (Some(project_common), Some(target_common)) => project_common == target_common,
        _ => false,
    }
}

/// Reject a project `.agents` directory that resolves outside the project
/// root before anything is written beneath it. [`write_file_no_follow`] only
/// guards the final path component; this closes the symlinked-ancestor escape
/// for callers that write under `.agents` without a refresh preflight (TUI
/// scope moves, agent-only adds). A `.agents` resolving into another worktree
/// of the same repository stays allowed — vstack's own `worktree` skill
/// provisions that layout (vstack#886).
pub(crate) fn ensure_agents_dir_within_project(project_root: &Path) -> Result<()> {
    let agents_dir = project_root.join(".agents");
    match std::fs::symlink_metadata(&agents_dir) {
        // Missing is fine: create_dir_all will make it inside the project.
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => bail!("failed to inspect project .agents directory: {err}"),
        Ok(_) => {}
    }
    let project_root_canon = project_root
        .canonicalize()
        .map_err(|err| anyhow::anyhow!("failed to resolve project root: {err}"))?;
    let agents_dir_canon = agents_dir
        .canonicalize()
        .map_err(|err| anyhow::anyhow!("failed to resolve .agents directory: {err}"))?;
    if !agents_dir_canon.starts_with(&project_root_canon)
        && !is_same_repository_worktree(&project_root_canon, &agents_dir_canon)
    {
        bail!(
            "refusing .agents path outside project root: {}",
            agents_dir.display()
        );
    }
    if !agents_dir_canon.is_dir() {
        bail!(
            "project .agents path is not a directory: {}",
            agents_dir.display()
        );
    }
    // Same boundary one level down: a real in-repo .agents whose skills
    // subdir symlinks outside the repository would otherwise pass, and every
    // skill write goes through .agents/skills.
    let skills_dir = agents_dir.join("skills");
    match std::fs::symlink_metadata(&skills_dir) {
        // Missing is fine: create_dir_all will make it inside the project.
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => bail!("failed to inspect project .agents/skills directory: {err}"),
        Ok(_) => {}
    }
    let skills_dir_canon = skills_dir
        .canonicalize()
        .map_err(|err| anyhow::anyhow!("failed to resolve .agents/skills directory: {err}"))?;
    if !skills_dir_canon.starts_with(&project_root_canon)
        && !is_same_repository_worktree(&project_root_canon, &skills_dir_canon)
    {
        bail!(
            "refusing .agents/skills path outside project root: {}",
            skills_dir.display()
        );
    }
    if !skills_dir_canon.is_dir() {
        bail!(
            "project .agents/skills path is not a directory: {}",
            skills_dir.display()
        );
    }
    Ok(())
}

pub(crate) fn ensure_file_write_target_safe(path: &Path) -> Result<()> {
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() {
            bail!("refusing to write through symlink: {}", path.display());
        }
        if meta.is_dir() {
            bail!("refusing to overwrite directory: {}", path.display());
        }
    }
    Ok(())
}

fn temp_sibling_path(path: &Path) -> Result<PathBuf> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow::anyhow!("path has no valid file name: {}", path.display()))?;
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    Ok(parent.join(format!(".{file_name}.{}.{}.tmp", std::process::id(), nanos)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_item_name_rejects_path_like_names() {
        for name in [
            "",
            ".",
            "-bad",
            "_bad",
            "../x",
            "a/b",
            "a\\b",
            "bad name",
            "has\nnewline",
            "bad`touch pwn`",
        ] {
            assert!(validate_item_name(name).is_err(), "accepted {name:?}");
        }
        assert!(validate_item_name("guard-hook").is_ok());
        assert!(validate_item_name("guard.hook_1").is_ok());
    }

    #[test]
    fn validate_new_item_name_rejects_reserved_shared_instruction_key() {
        for name in ["all", "All", "ALL"] {
            let err = validate_new_item_name(name).unwrap_err();
            assert!(
                err.to_string().contains("reserved"),
                "expected reserved-name error for {name:?}, got: {err}"
            );
            // Path-safety validation (used by removal) must keep accepting the
            // name so legacy installs stay deletable.
            assert!(validate_item_name(name).is_ok(), "rejected {name:?}");
        }
        // Names merely containing "all" stay valid everywhere.
        assert!(validate_new_item_name("allow").is_ok());
        assert!(validate_new_item_name("all-agents").is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn write_file_no_follow_rejects_final_symlink() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack-safe-write-symlink-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let outside = root.join("outside.txt");
        let link = root.join("link.txt");
        std::fs::write(&outside, "keep").unwrap();
        symlink(&outside, &link).unwrap();

        let err = write_file_no_follow(&link, "replace").unwrap_err();
        assert!(
            err.to_string()
                .contains("refusing to write through symlink")
        );
        assert_eq!(std::fs::read_to_string(&outside).unwrap(), "keep");

        let _ = std::fs::remove_dir_all(&root);
    }
}
