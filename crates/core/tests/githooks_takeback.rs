//! Taking back the retired hooks directory.
//!
//! Two generations of this binary armed commits by writing a hooks
//! directory inside the git directory and pointing `core.hooksPath` at it.
//! Nothing writes one any more — the growth-guards package's `.git/hooks`
//! shims are the arming that survived — but repositories out there still
//! carry them, and `core.hooksPath` makes the package's installer stand
//! down, so the takeback is what lets a repository cross over.
//!
//! Every install below is forged by hand, because that is now the only way
//! one exists. What is pinned here is the removal: receipt-scoped, with
//! compare-and-swap on both sides, proving ownership by content where the
//! receipt is gone, and refusing rather than half-removing.
#![cfg(unix)]

use std::path::{Path, PathBuf};

use kendex_core::env::{Env, FakeOs};
use kendex_core::githooks;
use kendex_core::process::Hardened;

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    repo: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn git(root: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(root)).run().unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let repo = home.join("proj");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet", "-b", "main"]);
    git(&repo, &["config", "user.email", "t@t"]);
    git(&repo, &["config", "user.name", "t"]);
    std::fs::write(repo.join("a.txt"), "hi\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "--quiet", "-m", "feat: base"]);
    World {
        env: Env::fake(&home, FakeOs::Linux),
        home,
        repo,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn config_value(repo: &Path, key: &str) -> Option<String> {
    let output = Hardened::git(&["config", "--get", key], Some(repo))
        .run()
        .unwrap();
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// Which generation an install belongs to: the directory name it used and
/// the entrypoint bytes it wrote.
#[derive(Clone, Copy)]
enum Generation {
    Kendex,
    Vstack,
}

impl Generation {
    fn dir(self) -> &'static str {
        match self {
            Generation::Kendex => ".git/kendex-hooks",
            Generation::Vstack => ".git/vstack-hooks",
        }
    }

    fn bytes(self, hook: &str) -> String {
        match self {
            Generation::Kendex => githooks::entrypoint(hook),
            Generation::Vstack => githooks::old_entrypoint(hook),
        }
    }
}

/// An install exactly as that generation's binary left it: the directory
/// holding its own entrypoint bytes, its receipt (optionally), and
/// `core.hooksPath` pointing at it. `leases` names the worktree roots the
/// receipt records; empty means this repository's own root.
#[allow(clippy::unwrap_used)]
fn arm(repo: &Path, generation: Generation, with_receipt: bool, leases: &[&Path]) -> PathBuf {
    let hooks_dir = repo.join(generation.dir());
    std::fs::create_dir_all(&hooks_dir).unwrap();
    use std::os::unix::fs::PermissionsExt;
    for hook in githooks::HOOKS {
        let path = hooks_dir.join(hook);
        std::fs::write(&path, generation.bytes(hook)).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    if with_receipt {
        let held = match leases.is_empty() {
            true => vec![repo.display().to_string()],
            false => leases.iter().map(|p| p.display().to_string()).collect(),
        };
        let receipt = githooks::Receipt {
            schema: 1,
            hooks_path: hooks_dir.display().to_string(),
            files: githooks::HOOKS
                .iter()
                .map(|name| (*name).to_owned())
                .chain(std::iter::once("receipt.json".to_owned()))
                .collect(),
            leases: held.into_iter().collect(),
        };
        let mut text = serde_json::to_string_pretty(&receipt).unwrap();
        text.push('\n');
        std::fs::write(hooks_dir.join("receipt.json"), text).unwrap();
    }
    git(
        repo,
        &["config", "core.hooksPath", &hooks_dir.display().to_string()],
    );
    hooks_dir
}

/// A repository with nothing of ours in it needs no takeback, and says so
/// without taking any lock.
#[test]
#[allow(clippy::unwrap_used)]
fn a_repository_with_nothing_of_ours_is_left_alone() {
    let w = world();
    assert!(!githooks::installed(&w.repo).unwrap());
    let report = githooks::uninstall(&w.env, &w.repo).unwrap();
    assert_eq!(
        report.lines.first().map(String::as_str),
        Some("no kendex hooks are installed in this repository")
    );
}

/// The ordinary takeback: the directory goes, `core.hooksPath` is unset,
/// and the repository is free for the package's installer to arm.
#[test]
#[allow(clippy::unwrap_used)]
fn a_current_generation_install_is_taken_back_whole() {
    let w = world();
    let hooks_dir = arm(&w.repo, Generation::Kendex, true, &[]);
    assert!(githooks::installed(&w.repo).unwrap());

    githooks::uninstall(&w.env, &w.repo).unwrap();
    assert!(!hooks_dir.exists());
    assert_eq!(config_value(&w.repo, "core.hooksPath"), None);
    assert!(!githooks::installed(&w.repo).unwrap());
}

/// An install the vstack-named binary made is taken back where it stands.
/// Its directory keeps the old name until it goes; moving it would be a
/// different mutation than removing it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_old_generation_install_is_taken_back_in_place() {
    let w = world();
    let hooks_dir = arm(&w.repo, Generation::Vstack, true, &[]);
    assert!(githooks::installed(&w.repo).unwrap());

    githooks::uninstall(&w.env, &w.repo).unwrap();
    assert!(!hooks_dir.exists());
    assert!(!w.repo.join(".git/kendex-hooks").exists());
    assert_eq!(config_value(&w.repo, "core.hooksPath"), None);
}

/// Without a receipt, ownership is proven by content: a directory holding
/// nothing but either generation's entrypoint bytes is ours by
/// construction. A missing hook does not change that — what is there is
/// still only ours.
#[test]
#[allow(clippy::unwrap_used)]
fn a_receiptless_directory_of_our_own_bytes_is_ours_by_content() {
    let w = world();
    let hooks_dir = arm(&w.repo, Generation::Kendex, false, &[]);
    std::fs::remove_file(hooks_dir.join("commit-msg")).unwrap();
    assert!(githooks::installed(&w.repo).unwrap());

    let report = githooks::uninstall(&w.env, &w.repo).unwrap();
    assert!(
        report
            .lines
            .iter()
            .any(|l| l.contains("only kendex's own entrypoints")),
        "{report:?}"
    );
    assert!(!hooks_dir.exists());
    assert_eq!(config_value(&w.repo, "core.hooksPath"), None);
}

/// A file kendex cannot prove it wrote is never removed around. The config
/// value is ours by name so it is unset, the directory stays, and the
/// foreign file is named so the reader can move it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_foreign_file_survives_the_takeback_and_is_named() {
    let w = world();
    let hooks_dir = arm(&w.repo, Generation::Kendex, false, &[]);
    std::fs::write(hooks_dir.join("theirs"), "#!/bin/sh\n").unwrap();

    let report = githooks::uninstall(&w.env, &w.repo).unwrap();
    assert!(
        report.lines.iter().any(|l| l.contains("theirs")),
        "{report:?}"
    );
    assert!(hooks_dir.join("theirs").is_file());
    assert_eq!(config_value(&w.repo, "core.hooksPath"), None);
}

/// With a receipt, a foreign file refuses the whole removal: unsetting
/// `core.hooksPath` around a surviving user hook would silently disable it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_foreign_file_under_a_receipt_refuses_rather_than_half_removing() {
    let w = world();
    let hooks_dir = arm(&w.repo, Generation::Kendex, true, &[]);
    std::fs::write(hooks_dir.join("theirs"), "#!/bin/sh\n").unwrap();

    let error = githooks::uninstall(&w.env, &w.repo).unwrap_err();
    assert!(error.to_string().contains("theirs"), "{error}");
    assert!(hooks_dir.join("pre-commit").is_file(), "nothing removed");
    assert!(config_value(&w.repo, "core.hooksPath").is_some());
}

/// A hand-deleted directory must not strand `core.hooksPath`: the value is
/// ours by name even with nothing behind it, and leaving it makes git run
/// no hook at all — including the repository's own.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hooks_path_left_pointing_at_a_deleted_directory_is_unset() {
    let w = world();
    let hooks_dir = arm(&w.repo, Generation::Vstack, true, &[]);
    std::fs::remove_dir_all(&hooks_dir).unwrap();
    assert!(githooks::installed(&w.repo).unwrap());

    let report = githooks::uninstall(&w.env, &w.repo).unwrap();
    assert!(
        report.lines.iter().any(|l| l.contains("unset")),
        "{report:?}"
    );
    assert_eq!(config_value(&w.repo, "core.hooksPath"), None);
}

/// A `core.hooksPath` someone changed by hand is not ours to unset. The
/// directory still goes; the value they chose survives.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_changed_hooks_path_survives_the_takeback() {
    let w = world();
    let hooks_dir = arm(&w.repo, Generation::Kendex, true, &[]);
    let theirs = w.home.join("their-hooks");
    std::fs::create_dir_all(&theirs).unwrap();
    git(
        &w.repo,
        &["config", "core.hooksPath", &theirs.display().to_string()],
    );

    let report = githooks::uninstall(&w.env, &w.repo).unwrap();
    assert!(
        report.lines.iter().any(|l| l.contains("changed by hand")),
        "{report:?}"
    );
    assert!(!hooks_dir.exists());
    assert_eq!(
        config_value(&w.repo, "core.hooksPath"),
        Some(theirs.display().to_string())
    );
}

/// The install stays armed while any lease survives: a worktree releasing
/// its own does not disarm the repository for the others.
#[test]
#[allow(clippy::unwrap_used)]
fn a_release_that_is_not_the_last_lease_leaves_the_install_armed() {
    let w = world();
    git(&w.repo, &["worktree", "add", "--quiet", "../linked"]);
    let linked = w.home.join("linked");
    let hooks_dir = arm(&w.repo, Generation::Kendex, true, &[&w.repo, &linked]);

    let report = githooks::uninstall(&w.env, &linked).unwrap();
    assert!(
        report.lines.iter().any(|l| l.contains("lease released")),
        "{report:?}"
    );
    assert!(hooks_dir.join("pre-commit").is_file());
    assert!(config_value(&w.repo, "core.hooksPath").is_some());

    // The last lease takes the whole directory.
    githooks::uninstall(&w.env, &w.repo).unwrap();
    assert!(!hooks_dir.exists());
    assert_eq!(config_value(&w.repo, "core.hooksPath"), None);
}

/// A worktree that never held a lease says so and rewrites nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_worktree_without_a_lease_changes_nothing() {
    let w = world();
    git(&w.repo, &["worktree", "add", "--quiet", "../linked"]);
    let hooks_dir = arm(&w.repo, Generation::Kendex, true, &[&w.repo]);
    let receipt_path = hooks_dir.join("receipt.json");
    let receipt = std::fs::read_to_string(&receipt_path).unwrap();

    let report = githooks::uninstall(&w.env, &w.home.join("linked")).unwrap();
    assert!(
        report
            .lines
            .iter()
            .any(|l| l.contains("never enabled the commit checks")),
        "{report:?}"
    );
    assert_eq!(std::fs::read_to_string(&receipt_path).unwrap(), receipt);
    assert!(config_value(&w.repo, "core.hooksPath").is_some());
}

/// A worktree whose directory is gone stays in git's registry as prunable.
/// It is dead here: its lease is reaped in passing, so the last live
/// worktree can still disarm without a manual `git worktree prune` first.
#[test]
#[allow(clippy::unwrap_used)]
fn a_prunable_worktree_lease_is_reaped_rather_than_holding_the_install() {
    let w = world();
    git(&w.repo, &["worktree", "add", "--quiet", "../gone"]);
    let gone = w.home.join("gone");
    let hooks_dir = arm(&w.repo, Generation::Kendex, true, &[&w.repo, &gone]);
    std::fs::remove_dir_all(&gone).unwrap();

    let report = githooks::uninstall(&w.env, &w.repo).unwrap();
    assert!(
        report.lines.iter().any(|l| l.contains("reaped a lease")),
        "{report:?}"
    );
    assert!(!hooks_dir.exists());
    assert_eq!(config_value(&w.repo, "core.hooksPath"), None);
}

/// Leases and git's registry compare paths as text. A repository reached
/// through a symlink must resolve to the spelling the registry lists, or
/// the live worktree reads as dead and its lease is reaped out from under
/// it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_worktree_reached_through_a_symlink_is_one_live_lease() {
    let w = world();
    let link = w.home.join("link");
    std::os::unix::fs::symlink(&w.repo, &link).unwrap();
    let hooks_dir = arm(&w.repo, Generation::Kendex, true, &[&w.repo]);

    let report = githooks::uninstall(&w.env, &link).unwrap();
    assert!(
        !report.lines.iter().any(|l| l.contains("reaped a lease")),
        "the live worktree was mistaken for a dead one: {report:?}"
    );
    assert!(!hooks_dir.exists());
    assert_eq!(config_value(&w.repo, "core.hooksPath"), None);
}

/// git answers `--git-common-dir` relative to where it was asked, not to
/// the top level: from a subdirectory the answer is `../.git`, and joined
/// onto the top level it names the parent's repository — whose install
/// would then be taken back instead of this one's.
#[test]
#[allow(clippy::unwrap_used)]
fn a_takeback_from_a_subdirectory_reaches_this_repository_not_its_parent() {
    let w = world();
    let outer = arm(&w.repo, Generation::Kendex, true, &[]);
    let inner = w.repo.join("inner");
    std::fs::create_dir_all(inner.join("sub")).unwrap();
    git(&inner, &["init", "--quiet", "-b", "main"]);
    let inner_hooks = arm(&inner, Generation::Kendex, true, &[]);

    githooks::uninstall(&w.env, &inner.join("sub")).unwrap();
    assert!(!inner_hooks.exists());
    assert_eq!(config_value(&inner, "core.hooksPath"), None);
    assert!(outer.join("pre-commit").is_file(), "the parent was spared");
    assert!(config_value(&w.repo, "core.hooksPath").is_some());
}

/// A torn write inside the hooks directory is recovered by the launch
/// pass, which reads the common-dir journal every common-lock holder
/// writes.
#[test]
#[allow(clippy::unwrap_used)]
fn the_launch_pass_recovers_a_crashed_hook_mutation() {
    let w = world();
    arm(&w.repo, Generation::Kendex, true, &[]);
    let repo = githooks::Repo::at(&w.repo).unwrap();
    let key = kendex_core::apply::common_key(&repo.common_dir);
    let journal_dir = kendex_core::apply::journal::journal_dir_for(&w.env.journal_dir(), &key);
    let victim = repo.hooks_dir().unwrap().join("pre-commit");
    let before = std::fs::read_to_string(&victim).unwrap();
    kendex_core::apply::journal::write(&journal_dir, std::slice::from_ref(&victim)).unwrap();
    std::fs::write(&victim, "torn write").unwrap();

    let recovered = kendex_core::apply::recover_common_journals(&w.env).unwrap();
    assert_eq!(recovered.len(), 1, "{recovered:?}");
    assert!(
        recovered[0].0.starts_with("git-common-proj-"),
        "the key names the repository a person recognizes: {}",
        recovered[0].0
    );
    assert!(recovered[0].1.as_ref().unwrap());
    assert_eq!(std::fs::read_to_string(&victim).unwrap(), before);

    let again = kendex_core::apply::recover_common_journals(&w.env).unwrap();
    assert!(again.iter().all(|(_, result)| !result.as_ref().unwrap()));

    // A journal dir that cannot be listed is an error, not an empty list.
    std::fs::remove_dir_all(w.env.journal_dir()).unwrap();
    std::fs::write(w.env.journal_dir(), "not a directory").unwrap();
    assert!(kendex_core::apply::recover_common_journals(&w.env).is_err());
}

/// A stray directory under the other generation's name must never shadow
/// the one `core.hooksPath` actually points at: git runs the armed one, so
/// that vote wins over a receipt found elsewhere.
#[test]
#[allow(clippy::unwrap_used)]
fn a_stray_directory_never_shadows_the_armed_one() {
    let w = world();
    let armed = arm(&w.repo, Generation::Vstack, true, &[]);
    let stray = w.repo.join(".git/kendex-hooks");
    std::fs::create_dir_all(&stray).unwrap();
    std::fs::write(stray.join("receipt.json"), "{}\n").unwrap();

    githooks::uninstall(&w.env, &w.repo).unwrap();
    assert!(!armed.exists(), "the armed directory is the one taken back");
    assert!(
        stray.join("receipt.json").is_file(),
        "the stray is untouched"
    );
    assert_eq!(config_value(&w.repo, "core.hooksPath"), None);
}
