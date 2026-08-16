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

/// Interpret one line of `git rev-parse` output as a path, preserving raw
/// bytes on Unix: a non-UTF-8 checkout path must not be lossy-mangled into
/// U+FFFD (canonicalize would then fail and same-repository detection would
/// silently collapse to None). Strips ONLY the record terminator (`\n` /
/// `\r\n`) — a path legitimately ending in a space or tab must survive.
fn git_output_path(bytes: &[u8]) -> Option<PathBuf> {
    let mut end = bytes.len();
    if end > 0 && bytes[end - 1] == b'\n' {
        end -= 1;
    }
    if end > 0 && bytes[end - 1] == b'\r' {
        end -= 1;
    }
    let trimmed = &bytes[..end];
    if trimmed.is_empty() {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        Some(PathBuf::from(std::ffi::OsStr::from_bytes(trimmed)))
    }
    #[cfg(not(unix))]
    {
        Some(PathBuf::from(String::from_utf8_lossy(trimmed).into_owned()))
    }
}

/// `git rev-parse --show-toplevel` for `dir`, canonicalized. `None` when `dir`
/// is not inside a Git repository or the answer cannot be resolved — callers
/// fail closed.
pub(crate) fn git_toplevel(dir: &Path) -> Option<PathBuf> {
    // The hardened constructor pins the working directory and drops the
    // `GIT_DIR`/`GIT_WORK_TREE` family: an inherited override would answer for
    // a different repository than the one being anchored against.
    let output = crate::refresh_sources::hardened_git_command(dir)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    git_output_path(&output.stdout)?.canonicalize().ok()
}

/// `git rev-parse --git-common-dir` for `dir`, canonicalized. `None` when `dir`
/// is not inside a Git repository, when git is unavailable, or when the answer
/// cannot be resolved — every one of which must fail closed at the call site.
pub(crate) fn git_common_dir(dir: &Path) -> Option<PathBuf> {
    let output = crate::refresh_sources::hardened_git_command(dir)
        .args(["rev-parse", "--git-common-dir"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let reported = git_output_path(&output.stdout)?;
    // `--git-common-dir` is relative to the queried directory unless git is new
    // enough to have been asked for an absolute path, so resolve it against
    // `dir` rather than the process cwd.
    let absolute = if reported.is_absolute() {
        reported
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
    let output = crate::refresh_sources::hardened_git_command(dir)
        .args(["rev-parse", "--git-common-dir", "--show-toplevel"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let mut lines = output.stdout.splitn(2, |b| *b == b'\n');
    let common_reported = git_output_path(lines.next()?)?;
    let toplevel_reported = git_output_path(lines.next()?)?;
    // `--git-common-dir` may be reported relative to the queried directory;
    // resolve it against `dir` rather than the process cwd.
    let common_absolute = if common_reported.is_absolute() {
        common_reported
    } else {
        dir.join(common_reported)
    };
    let common = common_absolute.canonicalize().ok()?;
    let toplevel = toplevel_reported.canonicalize().ok()?;
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

/// Is `claimed_checkout` the OTHER checkout's copy of this project's root?
/// The project root may sit below the git toplevel (a project marker in a
/// subdirectory); the repo layout is identical in every checkout, so the
/// legitimate shared `.agents` parent is `<other toplevel>/<this project's
/// repo-relative suffix>` — for a toplevel project that degenerates to the
/// toplevel itself. Anything else (a nested decoy, a sibling project's
/// root) is refused; unresolvable answers fail closed.
fn is_corresponding_project_root(project_root_canon: &Path, claimed_checkout: &Path) -> bool {
    let Some(own_toplevel) = git_toplevel(project_root_canon) else {
        return false;
    };
    let Ok(suffix) = project_root_canon.strip_prefix(&own_toplevel) else {
        return false;
    };
    let Some(claimed_toplevel) = git_toplevel(claimed_checkout) else {
        return false;
    };
    claimed_toplevel.join(suffix) == *claimed_checkout
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
    // `.agents` itself must be a checkout-owned canonical root BEFORE the
    // skills child is considered: an alias like `.agents -> cli/src` with no
    // `skills` child yet would otherwise ride the NotFound early-return
    // below, and the subsequent install creates (and later recursively
    // replaces) `<aliased-dir>/skills/<name>` inside repository sources.
    if agents_dir_canon.starts_with(&project_root_canon) {
        if agents_dir_canon != project_root_canon.join(".agents") {
            bail!(
                "refusing .agents that resolves to a non-canonical in-project directory: {} -> {}",
                agents_dir.display(),
                agents_dir_canon.display()
            );
        }
    } else {
        let claimed_checkout = agents_dir_canon
            .parent()
            .map(Path::to_path_buf)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "cannot derive a checkout root from {}",
                    agents_dir_canon.display()
                )
            })?;
        if !agents_dir_canon.ends_with(Path::new(".agents"))
            || !is_corresponding_project_root(&project_root_canon, &claimed_checkout)
        {
            bail!(
                "refusing .agents that does not resolve to the corresponding project root's .agents in another checkout: {} -> {}",
                agents_dir.display(),
                agents_dir_canon.display()
            );
        }
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
    // Same-repository containment is necessary but not sufficient: a
    // `.agents/skills` symlinked to an arbitrary in-repo directory (e.g.
    // `../cli/src`, or `.agents -> .` making it the project's own `skills/`
    // source) would make install treat `<target>/<name>` as canonical and
    // recursively DELETE it on refresh. The resolved target must be exactly
    // the corresponding project root's `.agents/skills` in a checkout
    // sharing this project's Git common directory — the spelling suffix
    // alone would still admit a nested decoy like `<repo>/decoy/.agents/skills`.
    if skills_dir_canon.starts_with(&project_root_canon) {
        // In-project, the ONLY legitimate resolution is this project's own
        // `.agents/skills` — an alias like `.agents -> .` (making it the
        // project's `skills/` source dir) or a nested decoy such as
        // `<root>/decoy/.agents/skills` would otherwise become a canonical
        // destination that refresh recursively deletes.
        if skills_dir_canon != project_root_canon.join(".agents").join("skills") {
            bail!(
                "refusing .agents/skills that resolves to a non-canonical in-project directory: {} -> {}",
                skills_dir.display(),
                skills_dir_canon.display()
            );
        }
    } else {
        // Out-of-project (same-repository worktree sharing): the target must
        // be exactly the corresponding project root's `.agents/skills` in
        // the other checkout — the spelling suffix alone would still admit
        // a nested decoy in that worktree.
        if !skills_dir_canon.ends_with(Path::new(".agents/skills")) {
            bail!(
                "refusing .agents/skills that resolves to a non-skills-root directory: {} -> {}",
                skills_dir.display(),
                skills_dir_canon.display()
            );
        }
        let claimed_checkout = skills_dir_canon
            .parent()
            .and_then(Path::parent)
            .map(Path::to_path_buf)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "cannot derive a checkout root from {}",
                    skills_dir_canon.display()
                )
            })?;
        if !is_corresponding_project_root(&project_root_canon, &claimed_checkout) {
            bail!(
                "refusing .agents/skills whose parent is not the corresponding project root in another checkout: {} -> {} (expected {} at the checkout's copy of this project's repo-relative root)",
                skills_dir.display(),
                skills_dir_canon.display(),
                claimed_checkout.display()
            );
        }
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

    /// `.agents` aliased to an arbitrary in-repo directory must refuse even
    /// when its `skills` child does not exist yet — the NotFound early
    /// return must not skip root validation, or install creates (and later
    /// recursively replaces) `<aliased>/skills/<name>` inside sources.
    #[cfg(unix)]
    #[test]
    fn agents_alias_without_skills_child_is_rejected() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_agents_alias_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let decoy = root.join("src");
        std::fs::create_dir_all(&decoy).unwrap();
        symlink(&decoy, root.join(".agents")).unwrap();

        let err = ensure_agents_dir_within_project(&root).unwrap_err();
        assert!(
            err.to_string().contains("non-canonical in-project"),
            "expected the .agents alias refusal, got: {err}"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// The supported sharing layout must keep working when the vstack
    /// project root sits BELOW the git toplevel: `<wt>/apps/foo/.agents ->
    /// <main>/apps/foo/.agents` is the corresponding project root's
    /// `.agents`, while a SIBLING project's `.agents` in the same checkout
    /// is not and must refuse.
    #[cfg(unix)]
    #[test]
    fn nested_project_agents_shared_with_corresponding_checkout_root() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_nested_share_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let main = root.join("main");
        std::fs::create_dir_all(main.join("apps/foo/.agents/skills")).unwrap();
        std::fs::create_dir_all(main.join("apps/bar/.agents")).unwrap();
        std::fs::write(main.join("apps/foo/keep.txt"), "x").unwrap();
        let git = |args: &[&str], cwd: &Path| {
            let status = std::process::Command::new("git")
                .args(args)
                .current_dir(cwd)
                .status()
                .unwrap();
            assert!(status.success(), "git {args:?} failed");
        };
        git(&["init", "-q"], &main);
        git(&["add", "."], &main);
        git(
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "-qm",
                "init",
            ],
            &main,
        );
        git(&["worktree", "add", "-q", "--detach", "../wt"], &main);
        let wt_project = root.join("wt/apps/foo");
        // `.agents` dirs are untracked, so the worktree has none — share
        // the main checkout's, exactly as the worktree skill provisions.
        symlink(main.join("apps/foo/.agents"), wt_project.join(".agents")).unwrap();
        ensure_agents_dir_within_project(&wt_project).unwrap();

        std::fs::remove_file(wt_project.join(".agents")).unwrap();
        symlink(main.join("apps/bar/.agents"), wt_project.join(".agents")).unwrap();
        let err = ensure_agents_dir_within_project(&wt_project).unwrap_err();
        assert!(
            err.to_string().contains("corresponding project root"),
            "expected the corresponding-root refusal, got: {err}"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Same-repository containment alone must not admit a `.agents/skills`
    /// symlinked to an arbitrary in-repo directory: install would treat
    /// `<target>/<name>` as canonical and recursively delete it on refresh
    /// (e.g. `.agents/skills -> ../cli/src` destroying `cli/src/<name>`).
    #[cfg(unix)]
    #[test]
    fn agents_skills_resolving_to_non_skills_root_is_rejected() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_skills_nonroot_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let agents = root.join(".agents");
        let decoy = root.join("src");
        std::fs::create_dir_all(&agents).unwrap();
        std::fs::create_dir_all(&decoy).unwrap();
        symlink(&decoy, agents.join("skills")).unwrap();

        let err = ensure_agents_dir_within_project(&root).unwrap_err();
        assert!(
            err.to_string().contains("non-canonical in-project"),
            "expected the in-project refusal, got: {err}"
        );

        // The ordinary real layout stays accepted.
        std::fs::remove_file(agents.join("skills")).unwrap();
        std::fs::create_dir_all(agents.join("skills")).unwrap();
        ensure_agents_dir_within_project(&root).unwrap();

        let _ = std::fs::remove_dir_all(&root);
    }

    /// The name of the helper below, as libtest filters it.
    const OVERRIDE_HELPER: &str = "path_safety::tests::git_location_override_helper";

    fn temp_repo_root(label: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "vstack_{label}_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&root);
        root
    }

    fn init_repo(dir: &Path) {
        std::fs::create_dir_all(dir).unwrap();
        let status = std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(dir)
            .status()
            .unwrap();
        assert!(status.success(), "git init failed in {}", dir.display());
    }

    /// These three reads decide which repository an ownership boundary is
    /// judged against, and git answers an inherited `GIT_DIR`/`GIT_WORK_TREE`
    /// in preference to the directory it is pointed at — so an override
    /// exported by whatever invoked vstack (a git hook, a shell) would anchor
    /// every check to a repository the user never named.
    ///
    /// Proving that needs the override in a process's environment, and
    /// mutating this one's would leak into every test running beside it. The
    /// assertions therefore run in a child: this same test binary, re-invoked
    /// for the ignored helper below with the overrides set.
    #[test]
    fn identity_reads_ignore_an_inherited_git_location_override() {
        let root = temp_repo_root("git_location_override");
        let anchored = root.join("anchored");
        let elsewhere = root.join("elsewhere");
        init_repo(&anchored);
        init_repo(&elsewhere);

        crate::test_util::run_test_helper(
            OVERRIDE_HELPER,
            &[
                ("GIT_DIR", elsewhere.join(".git").as_os_str()),
                ("GIT_WORK_TREE", elsewhere.as_os_str()),
                ("VSTACK_TEST_ANCHORED_REPO", anchored.as_os_str()),
                ("VSTACK_TEST_ELSEWHERE_REPO", elsewhere.as_os_str()),
            ],
            None,
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    #[ignore = "driven by identity_reads_ignore_an_inherited_git_location_override, which supplies the repositories and the overrides"]
    fn git_location_override_helper() {
        let (Some(anchored), Some(elsewhere)) = (
            std::env::var_os("VSTACK_TEST_ANCHORED_REPO"),
            std::env::var_os("VSTACK_TEST_ELSEWHERE_REPO"),
        ) else {
            // Run directly (`--ignored` with no filter); there is nothing to
            // assert without the fixture the parent builds.
            return;
        };
        let anchored = std::fs::canonicalize(PathBuf::from(anchored)).unwrap();
        let elsewhere = std::fs::canonicalize(PathBuf::from(elsewhere)).unwrap();

        // Control: an unhardened `git` in `anchored` answers for `elsewhere`,
        // so the assertions below are about the hardening and not about an
        // override that never took effect.
        let unhardened = std::process::Command::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .current_dir(&anchored)
            .output()
            .unwrap();
        let unhardened = git_output_path(&unhardened.stdout)
            .unwrap()
            .canonicalize()
            .unwrap();
        assert_eq!(
            unhardened, elsewhere,
            "the fixture must actually redirect git for this test to prove anything"
        );

        assert_eq!(git_toplevel(&anchored), Some(anchored.clone()));
        assert_eq!(
            git_common_dir(&anchored),
            Some(anchored.join(".git").canonicalize().unwrap())
        );
        assert_eq!(
            git_repo_identity(&anchored),
            Some((
                anchored.join(".git").canonicalize().unwrap(),
                anchored.clone()
            ))
        );
    }
}
