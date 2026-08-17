use std::path::{Path, PathBuf};
use std::process::Command;

/// The skill that owns the git shims.
pub const SKILL_NAME: &str = "growth-guards";
/// Installer the growth-guards skill ships, relative to a skills directory.
const INSTALLER_REL: &str = "growth-guards/scripts/install-git-hooks";
/// Hook helper the installer writes into the repository's hooks directory.
const HELPER_NAME: &str = "vstack-guards";
/// Trailing marker on the delegating line the installer writes into a hook.
const HOOK_SENTINEL: &str = "# vstack-guards-hook";

/// Install (or repair) the growth-guards git shims after a project-scope
/// install. The skill owns the installer and its idempotence; this is the
/// call site that keeps a consumer's shims current.
///
/// Returns the one line to surface, or `None` when the skill is not installed
/// in this project. Never fails the install: an installer that cannot run is
/// a warning line, because guard wiring is not what `add`/`refresh` are for.
pub fn install_growth_guards_hooks(project_root: &Path) -> Option<String> {
    run_installer(project_root, &[]).note
}

/// Remove the shims before the skill's own files go away: left behind they
/// fail closed, blocking every subsequent commit in the repository.
pub fn uninstall_growth_guards_hooks(project_root: &Path) -> Result<Option<String>, String> {
    // Whether shims exist decides, not whether the skill or the repository
    // look healthy: only their absence makes skipping safe.
    let Some(shim) = installed_shim(project_root)
        .map_err(|detail| format!("growth-guards git hooks: {detail}"))?
    else {
        return Ok(None);
    };
    if locate_installer(project_root).is_none() {
        return Err(format!(
            "growth-guards git hooks: {} is installed but the skill's install-git-hooks is missing, \
             so the shims cannot be removed",
            crate::config::display_path(&shim)
        ));
    }
    let outcome = run_installer(project_root, &["--uninstall"]);
    if outcome.ok {
        return Ok(outcome.note);
    }
    Err(outcome
        .note
        .unwrap_or_else(|| "growth-guards git hooks: removal failed".to_string()))
}

/// Any installed shim: the helper, or a hook still carrying the delegating
/// line — which fails closed on its own.
///
/// The COMMON hooks directory is what the installer writes, and what a later
/// `core.hooksPath` hides rather than moves: shims dormant behind that setting
/// revive the moment it is unset, so they are still shims. `None` covers every
/// case where nothing can fire.
fn installed_shim(project_root: &Path) -> Result<Option<PathBuf>, String> {
    let output = match Command::new("git")
        .arg("-C")
        .arg(project_root)
        .args(["rev-parse", "--git-common-dir"])
        .output()
    {
        Ok(output) => output,
        // git itself could not run: whether shims exist is unknown, and
        // unknown is not permission to remove the skill around them.
        Err(err) => return Err(format!("could not run git: {err}")),
    };
    // git ran and said no: there is no repository, so no hook can fire.
    if !output.status.success() {
        return Ok(None);
    }
    let common = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if common.is_empty() {
        return Ok(None);
    }
    // A relative answer is relative to the repository; an absolute one wins.
    let hooks = project_root.join(common).join("hooks");
    let helper = hooks.join(HELPER_NAME);
    if helper.is_file() {
        return Ok(Some(helper));
    }
    // Read as BYTES: a hook is not required to be UTF-8, and one that failed
    // to decode would otherwise read as carrying no delegate. A hook that
    // exists but cannot be read is UNKNOWN, and unknown counts as a shim.
    // Existence is tested on the LINK, so a dangling symlink counts too: its
    // target can come back carrying a delegate.
    Ok(["pre-commit", "commit-msg"].into_iter().find_map(|hook| {
        let path = hooks.join(hook);
        match std::fs::read(&path) {
            Ok(bytes) => bytes
                .windows(HOOK_SENTINEL.len())
                .any(|window| window == HOOK_SENTINEL.as_bytes())
                .then_some(path),
            Err(_) if std::fs::symlink_metadata(&path).is_ok() => Some(path),
            Err(_) => None,
        }
    }))
}

/// What a run of the skill's installer produced: whether it left the hooks in
/// the state asked for, and the one line to surface (absent when the skill is
/// not installed and there was nothing to run).
struct InstallerOutcome {
    ok: bool,
    note: Option<String>,
}

fn run_installer(project_root: &Path, extra_args: &[&str]) -> InstallerOutcome {
    let done = |note: String| InstallerOutcome {
        ok: true,
        note: Some(note),
    };
    let failed = |note: String| InstallerOutcome {
        ok: false,
        note: Some(note),
    };
    let Some(installer) = locate_installer(project_root) else {
        return InstallerOutcome {
            ok: true,
            note: None,
        };
    };
    match git_work_tree_state(project_root) {
        Ok(true) => {}
        // No work tree is nothing to install and nothing to clean up.
        Ok(false) => {
            return done(format!(
                "growth-guards git hooks: skipped — {} is not a git work tree",
                crate::config::display_path(project_root)
            ));
        }
        Err(detail) => return failed(format!("growth-guards git hooks: not installed — {detail}")),
    }
    let output = match Command::new(&installer)
        .arg("--repo")
        .arg(project_root)
        .args(extra_args)
        .output()
    {
        Ok(output) => output,
        Err(err) => {
            return failed(format!(
                "growth-guards git hooks: not installed — could not run {}: {err}",
                crate::config::display_path(&installer)
            ));
        }
    };
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let summary = last_nonempty_line(&stdout);
    if output.status.success() {
        return done(summary.unwrap_or_else(|| "growth-guards git hooks: installed".to_string()));
    }
    // Name what happened: the installer's own last warning is the most
    // specific thing available, its summary next.
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let detail = last_nonempty_line(&stderr)
        .or(summary)
        .unwrap_or_else(|| format!("installer exited with {}", output.status));
    failed(format!("growth-guards git hooks: not installed — {detail}"))
}

/// Every project-scope skills directory a vstack install can write, plus the
/// source layout vstack itself has: the canonical `.agents/skills` for a
/// symlink install, a harness skills directory for a copy install. Relative by
/// design — resolution depends on the root it is given, never on the process
/// working directory. Kept in step with the shipped installer's `SKILL_ROOTS`
/// by a test.
const SKILL_ROOTS: &[&str] = &[
    ".agents/skills",
    ".claude/skills",
    ".cursor/rules",
    ".opencode/skills",
    "skills",
];

fn locate_installer(project_root: &Path) -> Option<PathBuf> {
    SKILL_ROOTS
        .iter()
        .map(|root| project_root.join(root).join(INSTALLER_REL))
        .find(|path| path.is_file())
}

/// Whether `root` sits inside a git work tree. `Err` means the question could
/// not be asked (no git on PATH), which is not the same answer as "no".
fn git_work_tree_state(root: &Path) -> Result<bool, String> {
    match Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["rev-parse", "--is-inside-work-tree"])
        .output()
    {
        Ok(output) => {
            Ok(output.status.success() && String::from_utf8_lossy(&output.stdout).trim() == "true")
        }
        Err(err) => Err(format!("could not run git: {err}")),
    }
}

fn last_nonempty_line(text: &str) -> Option<String> {
    text.lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty())
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn sandbox(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "vstack-git-hooks-{label}-{}-{nanos}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The shipped skill, installed into one of the skills directories a
    /// project install can use.
    fn install_skill_into(project: &Path, skills_rel: &str) {
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../skills/growth-guards")
            .canonicalize()
            .expect("the growth-guards skill ships in this repo");
        let skills = project.join(skills_rel);
        fs::create_dir_all(&skills).unwrap();
        std::os::unix::fs::symlink(source, skills.join("growth-guards")).unwrap();
    }

    /// The canonical location a symlink-method install writes.
    fn install_skill(project: &Path) {
        install_skill_into(project, ".agents/skills");
    }

    fn git(project: &Path, args: &[&str]) {
        let status = Command::new("git")
            .arg("-C")
            .arg(project)
            .args(args)
            // A committer identity of its own: a clean CI runner has no global
            // one, and a test that commits must not depend on the developer's.
            .env("GIT_AUTHOR_NAME", "test")
            .env("GIT_AUTHOR_EMAIL", "test@example.com")
            .env("GIT_COMMITTER_NAME", "test")
            .env("GIT_COMMITTER_EMAIL", "test@example.com")
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?} failed");
    }

    #[test]
    fn a_project_without_the_skill_reports_nothing() {
        let project = sandbox("no-skill");
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        let found = install_growth_guards_hooks(&project);
        assert_eq!(found, None);
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn a_non_git_project_skips_with_a_note() {
        let project = sandbox("non-git");
        install_skill(&project);
        let note = install_growth_guards_hooks(&project).expect("a note");
        assert!(
            note.contains("skipped") && note.contains("not a git work tree"),
            "unexpected note: {note}"
        );
        assert!(!project.join(".git").exists());
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn a_git_project_gets_the_shims_and_the_install_is_idempotent() {
        let project = sandbox("git-project");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);

        let note = install_growth_guards_hooks(&project).expect("a note");
        assert!(note.contains("armed"), "unexpected note: {note}");
        let hooks = project.join(".git/hooks");
        for hook in ["vstack-guards", "pre-commit", "commit-msg"] {
            assert!(hooks.join(hook).is_file(), "{hook} was not installed");
        }
        let pre_commit = fs::read_to_string(hooks.join("pre-commit")).unwrap();
        assert!(pre_commit.contains("vstack-guards"), "{pre_commit}");
        // core.hooksPath would redirect every hook and silently disable the
        // repo's existing ones, so the install must never set it.
        let config = Command::new("git")
            .arg("-C")
            .arg(&project)
            .args(["config", "--get", "core.hooksPath"])
            .output()
            .unwrap();
        assert!(String::from_utf8_lossy(&config.stdout).trim().is_empty());

        let again = install_growth_guards_hooks(&project);
        assert_eq!(again, Some(note));
        assert_eq!(
            fs::read_to_string(hooks.join("pre-commit")).unwrap(),
            pre_commit,
            "a repeat install must not change the shim"
        );
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn a_copy_method_install_is_found_from_any_working_directory() {
        let project = sandbox("copy-method");
        install_skill_into(&project, ".claude/skills");
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);

        let note = install_growth_guards_hooks(&project).expect("a note");
        assert!(note.contains("armed"), "unexpected note: {note}");
        assert!(project.join(".git/hooks/pre-commit").is_file());
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn an_installer_that_refuses_is_a_warning_line_not_a_failure() {
        let project = sandbox("refused");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        // A foreign file at the helper path is content the installer does not
        // own; it must refuse rather than overwrite.
        fs::write(
            project.join(".git/hooks/vstack-guards"),
            "#!/bin/sh\nexit 0\n",
        )
        .unwrap();

        let note = install_growth_guards_hooks(&project).expect("a note");
        assert!(note.contains("not installed"), "unexpected note: {note}");
        assert!(!project.join(".git/hooks/pre-commit").exists());
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn uninstalling_removes_the_shims_and_leaves_a_foreign_hook_intact() {
        let project = sandbox("uninstall");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        let foreign = "#!/bin/sh\necho mine\nexit 0\n";
        let hook = project.join(".git/hooks/pre-commit");
        fs::write(&hook, foreign).unwrap();
        let mut perms = fs::metadata(&hook).unwrap().permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o755);
        fs::set_permissions(&hook, perms).unwrap();
        install_growth_guards_hooks(&project).expect("installed");

        let note = uninstall_growth_guards_hooks(&project)
            .expect("cleanup succeeded")
            .expect("a note");
        assert!(note.contains("removed from"), "unexpected note: {note}");
        assert!(!project.join(".git/hooks/vstack-guards").exists());
        // A hook this installer created goes away; a consumer's own hook keeps
        // every line it had.
        assert!(!project.join(".git/hooks/commit-msg").exists());
        assert_eq!(fs::read_to_string(&hook).unwrap(), foreign);
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn a_damaged_install_with_live_shims_refuses_to_uninstall() {
        let project = sandbox("damaged");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        install_growth_guards_hooks(&project).expect("installed");
        // The skill's files are gone but its shims are still live: removing
        // the rest would leave hooks with no guard to reach.
        fs::remove_file(project.join(".agents/skills/growth-guards")).unwrap();

        let err = uninstall_growth_guards_hooks(&project).expect_err("must refuse");
        assert!(err.contains("install-git-hooks is missing"), "{err}");
        assert!(project.join(".git/hooks/vstack-guards").is_file());
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn a_delegate_without_its_helper_still_counts_as_an_installed_shim() {
        let project = sandbox("orphan-delegate");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        install_growth_guards_hooks(&project).expect("installed");
        // The delegate fails closed on its own: left behind it blocks every
        // commit, so its presence must still demand cleanup.
        fs::remove_file(project.join(".git/hooks/vstack-guards")).unwrap();
        fs::remove_file(project.join(".agents/skills/growth-guards")).unwrap();

        let err = uninstall_growth_guards_hooks(&project).expect_err("must refuse");
        assert!(err.contains("install-git-hooks is missing"), "{err}");
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn a_delegate_in_a_non_utf8_hook_is_still_found() {
        let project = sandbox("non-utf8");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        install_growth_guards_hooks(&project).expect("installed");
        // A hook is bytes, not text: an undecodable one still carries its
        // delegate, and that delegate still fails closed.
        let hook = project.join(".git/hooks/pre-commit");
        let mut bytes = fs::read(&hook).unwrap();
        bytes.extend_from_slice(&[b'#', 0xff, 0xfe, b'\n']);
        fs::write(&hook, &bytes).unwrap();
        // The undecodable hook must be the ONLY evidence left, or the probe
        // could find the delegate through its sibling instead.
        fs::remove_file(project.join(".git/hooks/commit-msg")).unwrap();
        fs::remove_file(project.join(".git/hooks/vstack-guards")).unwrap();
        fs::remove_file(project.join(".agents/skills/growth-guards")).unwrap();

        let err = uninstall_growth_guards_hooks(&project).expect_err("must refuse");
        assert!(err.contains("install-git-hooks is missing"), "{err}");
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn an_unreadable_hook_counts_as_a_shim() {
        let project = sandbox("unreadable-hook");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        install_growth_guards_hooks(&project).expect("installed");
        // Unknown content is not absence: a delegate could be in there, and
        // removing the skill around one blocks every commit.
        fs::remove_file(project.join(".git/hooks/commit-msg")).unwrap();
        fs::remove_file(project.join(".git/hooks/vstack-guards")).unwrap();
        let hook = project.join(".git/hooks/pre-commit");
        let mut perms = fs::metadata(&hook).unwrap().permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o300);
        fs::set_permissions(&hook, perms).unwrap();
        fs::remove_file(project.join(".agents/skills/growth-guards")).unwrap();

        let err = uninstall_growth_guards_hooks(&project).expect_err("must refuse");
        assert!(err.contains("install-git-hooks is missing"), "{err}");
        let mut perms = fs::metadata(&hook).unwrap().permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o755);
        let _ = fs::set_permissions(&hook, perms);
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn shims_dormant_behind_a_custom_hooks_path_are_still_found() {
        let project = sandbox("dormant");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        install_growth_guards_hooks(&project).expect("installed");
        // Set after the install: git reads elsewhere now, but unsetting it
        // revives the shims in .git/hooks.
        fs::create_dir_all(project.join("myhooks")).unwrap();
        git(&project, &["config", "core.hooksPath", "myhooks"]);

        let note = uninstall_growth_guards_hooks(&project)
            .expect("cleanup succeeded")
            .expect("a note");
        assert!(note.contains("removed from"), "unexpected note: {note}");
        assert!(!project.join(".git/hooks/vstack-guards").exists());
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn shims_are_found_from_a_linked_worktree() {
        let project = sandbox("linked-worktree");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        install_growth_guards_hooks(&project).expect("installed");
        fs::write(project.join("a.txt"), "hi\n").unwrap();
        git(&project, &["add", "a.txt"]);
        git(
            &project,
            &[
                "-c",
                "core.hooksPath=/dev/null",
                "commit",
                "-q",
                "-m",
                "feat: a",
            ],
        );
        // A linked worktree's --git-common-dir answers ABSOLUTE, and its hooks
        // are the main checkout's.
        let linked = project.join("linked");
        git(
            &project,
            &[
                "worktree",
                "add",
                "-q",
                linked.to_str().unwrap(),
                "-b",
                "linked",
            ],
        );
        install_skill(&linked);

        // The main checkout still has its own install, so the shared shims are
        // kept — which is only observable if the probe reached them at all.
        let note = uninstall_growth_guards_hooks(&linked)
            .expect("cleanup succeeded")
            .expect("a note");
        assert!(note.contains("kept"), "unexpected note: {note}");
        assert!(project.join(".git/hooks/vstack-guards").is_file());

        // With no separate install left, the same call removes them.
        fs::remove_file(project.join(".agents/skills/growth-guards")).unwrap();
        let note = uninstall_growth_guards_hooks(&linked)
            .expect("cleanup succeeded")
            .expect("a note");
        assert!(note.contains("removed from"), "unexpected note: {note}");
        assert!(!project.join(".git/hooks/vstack-guards").exists());
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn a_dangling_hook_symlink_counts_as_a_shim() {
        let project = sandbox("dangling-hook");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        install_growth_guards_hooks(&project).expect("installed");
        // Its target can come back carrying the delegate, so the link is
        // evidence even while it points at nothing.
        fs::remove_file(project.join(".git/hooks/commit-msg")).unwrap();
        fs::remove_file(project.join(".git/hooks/vstack-guards")).unwrap();
        let hook = project.join(".git/hooks/pre-commit");
        fs::remove_file(&hook).unwrap();
        std::os::unix::fs::symlink(project.join("gone"), &hook).unwrap();
        fs::remove_file(project.join(".agents/skills/growth-guards")).unwrap();

        let err = uninstall_growth_guards_hooks(&project).expect_err("must refuse");
        assert!(err.contains("install-git-hooks is missing"), "{err}");
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn uninstalling_where_no_shims_exist_is_a_silent_no_op() {
        let project = sandbox("no-shims");
        install_skill(&project);
        git(&project, &["-c", "init.defaultBranch=main", "init", "-q"]);
        assert_eq!(uninstall_growth_guards_hooks(&project), Ok(None));

        // Same answer without a repository at all — nothing git could run.
        let bare = sandbox("no-repo");
        install_skill(&bare);
        assert_eq!(uninstall_growth_guards_hooks(&bare), Ok(None));
        let _ = fs::remove_dir_all(&project);
        let _ = fs::remove_dir_all(&bare);
    }

    #[test]
    fn the_skill_roots_match_the_shipped_installers_own_list() {
        // One list, two languages: a root added on one side and not the other
        // is a layout the CLI or the helper would silently not find.
        let script = fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../skills/growth-guards/scripts/install-git-hooks"),
        )
        .expect("the installer ships in this repo");
        let line = script
            .lines()
            .find(|line| line.starts_with("SKILL_ROOTS="))
            .expect("the installer declares SKILL_ROOTS");
        let shell: Vec<&str> = line
            .trim_start_matches("SKILL_ROOTS=")
            .trim_matches('"')
            .split_whitespace()
            .collect();
        assert_eq!(
            shell, SKILL_ROOTS,
            "SKILL_ROOTS drifted between CLI and script"
        );
    }

    #[test]
    fn last_nonempty_line_picks_the_final_line_with_content() {
        assert_eq!(last_nonempty_line("a\nb\n\n  \n"), Some("b".to_string()));
        assert_eq!(last_nonempty_line("  only  "), Some("only".to_string()));
        assert_eq!(last_nonempty_line("\n \n"), None);
        assert_eq!(last_nonempty_line(""), None);
    }
}
