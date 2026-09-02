//! The chain judging commits: what an armed repository does when someone
//! commits to it, and which copy of the package answers.

use crate::{
    armed_repo, git, git_ok, install_package, path_with_binary, path_without_binary, repo, run,
    run_with, said,
};
use std::process::Command;

/// The shims are armed, a plain `git commit` runs the package's chain, and
/// A work marker for a fixture to write, spelled in halves.
///
/// The check under test scans this repository too, so a fixture that spells
/// the word it is about would fail the very gate it proves works — and the
/// failure would name the test file, not the code. The suite this replaced
/// split it the same way; spelling it whole is what turned the lane red.
fn work_marker(head: &str, tail: &str) -> String {
    format!("// {head}{tail}\n")
}

/// a violation the package defines blocks the commit.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plain_commit_walks_through_the_packages_chain() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);

    assert!(root.join(".git/hooks/kendex-guards").is_file());
    let hook = std::fs::read_to_string(root.join(".git/hooks/pre-commit")).unwrap();
    assert!(hook.contains("kendex-guards-hook"), "{hook}");

    std::fs::write(root.join("b.rs"), work_marker("TO", "DO: not yet")).unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = git(home, &root, &["commit", "-m", "feat: adds a marker"]);
    assert!(!blocked.status.success());
    let text = said(&blocked);
    assert!(text.contains("todo-ban"), "{text}");
}

/// The gate needs no kendex binary. Once the shims are written, git runs
/// committed shell and nothing else — which is what makes a clone of a
/// repository gate commits on a machine that never installed kendex.
#[test]
#[allow(clippy::unwrap_used)]
fn the_armed_gate_still_blocks_with_no_kendex_on_path() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);

    std::fs::write(root.join("b.rs"), work_marker("FIX", "ME: later")).unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = run_with(
        home,
        &root,
        "git",
        &["commit", "-m", "feat: adds a marker"],
        &[("PATH", &path_without_binary())],
    );
    assert!(!blocked.status.success(), "{}", said(&blocked));
    assert!(said(&blocked).contains("todo-ban"), "{}", said(&blocked));
}

/// The commit-msg lane runs too, on the message file git hands the hook.
#[test]
#[allow(clippy::unwrap_used)]
fn the_message_gate_judges_what_git_passes_the_hook() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);

    std::fs::write(root.join("b.txt"), "fine\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = git(home, &root, &["commit", "-m", "not conventional at all"]);
    assert!(!blocked.status.success(), "{}", said(&blocked));

    let ok = git(home, &root, &["commit", "-m", "feat: conventional"]);
    assert!(ok.status.success(), "{}", said(&ok));
}

/// An existing hook keeps its content and its exit status: the package's
/// line goes first and falls through to whatever was already there.
#[test]
#[allow(clippy::unwrap_used)]
fn an_existing_hook_keeps_its_content_and_its_verdict() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let existing = root.join(".git/hooks/pre-commit");
    std::fs::write(&existing, "#!/bin/sh\necho theirs ran\nexit 3\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&existing, std::fs::Permissions::from_mode(0o755)).unwrap();

    install_package(home, &root, &["growth-guards"]);
    let install = run(home, &root, "kendex", &["guard", "install"]);
    assert!(install.status.success(), "{}", said(&install));

    let hook = std::fs::read_to_string(&existing).unwrap();
    assert!(hook.contains("echo theirs ran"), "{hook}");
    assert!(hook.contains("kendex-guards-hook"), "{hook}");

    std::fs::write(root.join("b.txt"), "fine\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    // The chain passes, so the existing hook is what git hears from — and
    // its nonzero is what stops the commit. git reports a failed hook as
    // its own exit 1 whatever the hook returned, so the proof the hook
    // decided is that a clean chain still blocked, in its words.
    let blocked = git(home, &root, &["commit", "-m", "feat: clean"]);
    assert!(!blocked.status.success(), "{}", said(&blocked));
    assert!(said(&blocked).contains("theirs ran"), "{}", said(&blocked));
    assert!(
        said(&blocked).contains("pre-commit: OK"),
        "the chain itself was clean: {}",
        said(&blocked)
    );
}

/// The stand-in gate, for a repository where nothing has been armed. With
/// no package installed there is nothing to run, and a gate that cannot run
/// refuses rather than passing the commit.
#[test]
#[allow(clippy::unwrap_used)]
fn the_stand_in_gate_refuses_where_the_package_is_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);

    let out = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(said(&out).contains("growth-guards"), "{}", said(&out));
}

/// With the package installed but no shim armed, the stand-in gate runs the
/// same chain the shim would have.
#[test]
#[allow(clippy::unwrap_used)]
fn the_stand_in_gate_runs_the_same_chain_the_shim_would() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    std::fs::write(root.join("b.rs"), work_marker("TO", "DO: not yet")).unwrap();
    git_ok(home, &root, &["add", "-A"]);

    let out = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(said(&out).contains("todo-ban"), "{}", said(&out));
}

/// A sibling gate the work tree carries joins the chain, and one it does
/// not carry is an announced skip rather than a silently missing check.
#[test]
#[allow(clippy::unwrap_used)]
fn sibling_gates_join_the_chain_and_absent_ones_announce_themselves() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);

    let without = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert!(
        said(&without).contains("size-ratchet not installed"),
        "{}",
        said(&without)
    );

    install_package(home, &root, &["size-ratchet"]);
    let with = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert!(
        said(&with).contains("=== pre-commit: size-ratchet"),
        "{}",
        said(&with)
    );
    assert!(
        !said(&with).contains("size-ratchet not installed"),
        "{}",
        said(&with)
    );
}

/// The commit-msg lane takes the relative path git hands a hook, resolved
/// against where the caller stood — not rebased on the repository root,
/// where that name is a file that does not exist.
#[test]
#[allow(clippy::unwrap_used)]
fn the_message_lane_resolves_a_relative_path_against_the_caller() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let sub = root.join("sub");
    std::fs::create_dir_all(&sub).unwrap();
    std::fs::write(sub.join("MSG"), "not conventional at all\n").unwrap();

    let out = run(home, &sub, "kendex", &["guard", "run", "commit-msg", "MSG"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(said(&out).contains("commit-msg"), "{}", said(&out));
}

/// With no file, the message arrives on stdin. A hardened child pointed at
/// /dev/null would read an empty message and fail every piped commit.
#[test]
#[allow(clippy::unwrap_used)]
fn the_message_lane_reads_a_piped_message() {
    use std::io::Write;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);

    let mut child = Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(["guard", "run", "commit-msg"])
        .current_dir(&root)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", path_with_binary())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"feat: piped and conventional\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(0), "{}", said(&out));
}

/// The resolver mirrors the generated helper: the main checkout is searched
/// before this work tree, so a linked worktree carrying no copy of the
/// package is gated by the main checkout's — and must not read as a
/// repository with stale shims and no package.
#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_worktree_is_served_by_the_main_checkouts_copy() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);
    git_ok(home, &root, &["worktree", "add", "--quiet", "../linked"]);
    let linked = home.join("linked");
    assert!(
        !linked.join(".agents/skills/growth-guards").exists(),
        "the linked worktree carries no copy of its own"
    );

    // The chain runs there, resolved from the main checkout.
    std::fs::write(linked.join("b.rs"), work_marker("TO", "DO: not yet")).unwrap();
    git_ok(home, &linked, &["add", "-A"]);
    let blocked = git(home, &linked, &["commit", "-m", "feat: adds a marker"]);
    assert!(!blocked.status.success(), "{}", said(&blocked));
    assert!(said(&blocked).contains("todo-ban"), "{}", said(&blocked));

    // And the check reports it armed rather than stale.
    let out = run(home, &linked, "kendex", &["check"]);
    assert!(
        !said(&out).contains("still carries"),
        "the shared shims are not stale: {}",
        said(&out)
    );
}

/// The main checkout is searched at the PROJECT's path, not only at its top
/// level.
///
/// A repository whose projects sit under `apps/web` installs the package at
/// `<main>/apps/web/.agents/skills`. A linked worktree carries the committed
/// manifest but no `.agents`, so resolving from `<linked>/apps/web` has to
/// cross to `<main>/apps/web` — searching `<main>` alone finds nothing and
/// reports a package the commit hook is running perfectly well as missing.
#[test]
#[allow(clippy::unwrap_used)]
fn the_main_checkout_is_searched_at_the_projects_path() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let project = root.join("apps/web");
    std::fs::create_dir_all(project.join(".agents")).unwrap();
    install_package(home, &project, &["growth-guards"]);
    let install = run(home, &project, "kendex", &["guard", "install"]);
    assert!(install.status.success(), "{}", said(&install));

    // The manifest is committed and the render is not, which is what a
    // linked worktree of such a repository actually contains.
    std::fs::write(root.join(".gitignore"), ".agents/\n").unwrap();
    git_ok(home, &root, &["add", ".gitignore", "apps/web/kendex.toml"]);
    git_ok(
        home,
        &root,
        &["commit", "--quiet", "-m", "feat: the project"],
    );
    git_ok(home, &root, &["worktree", "add", "--quiet", "../linked"]);
    let there = home.join("linked/apps/web");
    assert!(
        there.join("kendex.toml").is_file() && !there.join(".agents").exists(),
        "the linked worktree carries the manifest and no render"
    );

    let out = run(home, &there, "kendex", &["guard", "check"]);
    assert!(
        !said(&out).contains("no growth-guards skill"),
        "the main checkout's copy went unfound: {}",
        said(&out)
    );
    assert!(said(&out).contains("armed"), "{}", said(&out));
}

/// A directory inside this work tree is not this repository's main checkout.
///
/// git resolves upward, so "does this candidate's common git dir match
/// ours" answers yes about every directory below our own top level. A git
/// directory at `<checkout>/meta/repo.git` makes the parent `<checkout>/meta`
/// — inside the work tree, not a checkout root — and a `growth-guards` under
/// it would be resolved as this repository's package. Being the root is the
/// second test.
#[test]
#[allow(clippy::unwrap_used)]
fn a_directory_inside_the_work_tree_is_not_the_main_checkout() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    let root = home.join("proj");
    std::fs::create_dir_all(root.join("meta")).unwrap();
    std::fs::create_dir_all(root.join(".agents")).unwrap();
    git_ok(
        home,
        home,
        &[
            "init",
            "--quiet",
            "-b",
            "main",
            "--separate-git-dir",
            root.join("meta/repo.git").to_str().unwrap(),
            root.to_str().unwrap(),
        ],
    );
    git_ok(home, &root, &["config", "user.email", "t@t"]);
    git_ok(home, &root, &["config", "user.name", "t"]);

    // The decoy sits where the git directory's parent points, inside the
    // work tree. It is the only copy with an executable script.
    let decoy = root.join("meta/.agents/skills/growth-guards/scripts");
    std::fs::create_dir_all(&decoy).unwrap();
    for lane in ["pre-commit", "commit-msg", "install-git-hooks"] {
        let script = decoy.join(lane);
        std::fs::write(&script, "#!/bin/sh\nexit 0\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    let out = run(home, &root, "kendex", &["guard", "check"]);
    let said = said(&out);
    assert!(
        !said.contains("meta/.agents"),
        "a package inside the work tree was resolved as the main checkout's: {said}"
    );
    assert!(
        said.contains("no growth-guards skill"),
        "the only copy here is the decoy, so nothing should resolve: {said}"
    );
}

/// A tool directory holding a broken copy must not shadow a working one
/// beside it: the helper takes the first root whose script is executable,
/// and so does this.
#[test]
#[allow(clippy::unwrap_used)]
fn a_broken_copy_does_not_shadow_a_working_one() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    // `.agents/skills` is searched before `skills`, so put the broken copy
    // there and the working one after it.
    std::fs::rename(
        root.join(".agents/skills/growth-guards"),
        root.join("skills-tmp"),
    )
    .unwrap();
    std::fs::create_dir_all(root.join("skills")).unwrap();
    std::fs::rename(root.join("skills-tmp"), root.join("skills/growth-guards")).unwrap();
    let broken = root.join(".agents/skills/growth-guards/scripts");
    std::fs::create_dir_all(&broken).unwrap();
    for lane in ["pre-commit", "install-git-hooks"] {
        let path = broken.join(lane);
        std::fs::write(&path, "#!/bin/sh\nexit 9\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    }

    std::fs::write(root.join("b.rs"), work_marker("TO", "DO: not yet")).unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let out = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(said(&out).contains("todo-ban"), "{}", said(&out));
}

/// A checkout path holding an apostrophe: the installer escapes it into the
/// helper, so reading it back has to undo that. Both sides must land on the
/// same directory, or the shim runs a copy kendex cannot find.
#[test]
#[allow(clippy::unwrap_used)]
fn a_path_with_an_apostrophe_resolves_the_same_on_both_sides() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = home.join("o'brien/proj");
    std::fs::create_dir_all(root.join(".agents")).unwrap();
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    git_ok(home, &root, &["init", "--quiet", "-b", "main"]);
    git_ok(home, &root, &["config", "user.email", "t@t"]);
    git_ok(home, &root, &["config", "user.name", "t"]);
    std::fs::write(root.join("a.txt"), "hi\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    git_ok(home, &root, &["commit", "--quiet", "-m", "feat: base"]);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The helper carries the escaped spelling.
    let helper = std::fs::read_to_string(root.join(".git/hooks/kendex-guards")).unwrap();
    assert!(helper.contains("'\\''"), "the path was escaped: {helper}");

    // Both sides run the same copy: a real commit, and kendex's own lane.
    std::fs::write(root.join("b.rs"), work_marker("TO", "DO: not yet")).unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = git(home, &root, &["commit", "-m", "feat: adds a marker"]);
    assert!(!blocked.status.success(), "{}", said(&blocked));
    assert!(said(&blocked).contains("todo-ban"), "{}", said(&blocked));

    let out = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(said(&out).contains("todo-ban"), "{}", said(&out));
}

/// A kendex project can sit below the git top level, and the package
/// renders under the PROJECT's root.
///
/// A repository holding several projects renders each under its own root, so
/// a resolver that looked only at the git top level would find none of them
/// and call a properly installed project unarmed. The manifest is what says
/// where the project is, so that is where the search starts.
#[test]
#[allow(clippy::unwrap_used)]
fn a_project_below_the_git_toplevel_is_found_where_it_renders() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    // The git repository, with no project at its root.
    // Detection reads this: without a tool directory an install has nowhere
    // to fan out to.
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    let outer = home.join("monorepo");
    std::fs::create_dir_all(&outer).unwrap();
    git_ok(home, &outer, &["init", "--quiet", "-b", "main"]);
    git_ok(home, &outer, &["config", "user.email", "t@t"]);
    git_ok(home, &outer, &["config", "user.name", "t"]);
    std::fs::write(outer.join("README.md"), "the monorepo\n").unwrap();
    git_ok(home, &outer, &["add", "-A"]);
    git_ok(home, &outer, &["commit", "--quiet", "-m", "feat: base"]);

    // The project, two levels down, installed there.
    let project = outer.join("apps/web");
    std::fs::create_dir_all(project.join(".agents")).unwrap();
    install_package(home, &project, &["growth-guards"]);
    assert!(
        project.join(".agents/skills/growth-guards").is_dir(),
        "the render lands under the project root"
    );
    assert!(
        !outer.join(".agents/skills/growth-guards").exists(),
        "and not at the git top level"
    );

    // The chain runs from there, resolved through the project's manifest.
    std::fs::write(project.join("b.rs"), work_marker("TO", "DO: not yet")).unwrap();
    git_ok(home, &outer, &["add", "-A"]);
    let out = run(home, &project, "kendex", &["guard", "run", "pre-commit"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(said(&out).contains("todo-ban"), "{}", said(&out));

    // And arming from there gates a real commit.
    let armed = run(home, &project, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));
    let blocked = git(home, &project, &["commit", "-m", "feat: adds a marker"]);
    assert!(!blocked.status.success(), "{}", said(&blocked));
    assert!(said(&blocked).contains("todo-ban"), "{}", said(&blocked));
}

/// A tampered helper cannot redirect the guard verbs.
///
/// The helper names the scripts an armed repository runs, and the verbs read
/// that name so they judge the copy the shim would. But a name is not
/// evidence: `.git/hooks` is ordinary local state, so a file carrying an
/// `installed_scripts=` line and anything else at all would point every verb
/// at whatever executable it chose. The whole file has to be the helper an
/// install of that directory writes, or the name is ignored.
#[test]
#[allow(clippy::unwrap_used)]
fn a_tampered_helper_does_not_redirect_the_guard_verbs() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    let armed = run_with(
        home,
        &root,
        installer.to_str().unwrap(),
        &["--repo", root.to_str().unwrap()],
        &[],
    );
    assert!(armed.status.success(), "{}", said(&armed));

    // Somewhere else entirely, with scripts that would announce themselves.
    let elsewhere = home.join("elsewhere/scripts");
    std::fs::create_dir_all(&elsewhere).unwrap();
    let marker = home.join("elsewhere-ran");
    for lane in ["pre-commit", "commit-msg"] {
        let path = elsewhere.join(lane);
        std::fs::write(
            &path,
            format!("#!/usr/bin/env bash\ntouch {}\nexit 0\n", marker.display()),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    // A helper that names them, and is otherwise not the helper: an extra
    // line is enough, and is what tampering actually looks like.
    let helper = root.join(".git/hooks/kendex-guards");
    let genuine = std::fs::read_to_string(&helper).unwrap();
    let redirected: String = genuine
        .lines()
        .map(|line| match line.starts_with("installed_scripts='") {
            true => format!("installed_scripts='{}'", elsewhere.display()),
            false => line.to_owned(),
        })
        .collect::<Vec<_>>()
        .join("\n");
    std::fs::write(&helper, format!("{redirected}\n# and one more thing\n")).unwrap();
    std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();

    // The verbs fall through to the search roots and run the real package.
    std::fs::write(root.join("b.rs"), work_marker("TO", "DO: not yet")).unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let out = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert!(
        !marker.exists(),
        "a tampered helper redirected the verb: {}",
        said(&out)
    );
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(said(&out).contains("todo-ban"), "{}", said(&out));
}

/// A package next to the git directory is not this repository's package.
///
/// `<main>/.git` is the ordinary layout, and the directory holding the
/// common git dir is the main checkout there. Under `--separate-git-dir` the
/// git directory lives outside the checkout, so its parent is an unrelated
/// directory — and one holding a `growth-guards` of its own would have been
/// searched and executed as this repository's commit gate.
///
/// Owning it is the test: the candidate's own common git dir must be this
/// repository's, which is what the package's installer already asks.
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_beside_an_external_git_dir_does_not_govern() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();

    // The git directory lives outside the checkout, so `common_dir.parent()`
    // is `outside/` — which belongs to nobody.
    let outside = home.join("outside");
    let root = outside.join("checkout");
    let gitdir = outside.join("elsewhere.git");
    std::fs::create_dir_all(&root).unwrap();
    let init = run_with(
        home,
        &outside,
        "git",
        &[
            "init",
            "-q",
            "--separate-git-dir",
            gitdir.to_str().unwrap(),
            root.to_str().unwrap(),
        ],
        &[],
    );
    assert!(init.status.success(), "{}", said(&init));
    git_ok(home, &root, &["config", "user.email", "t@t"]);
    git_ok(home, &root, &["config", "user.name", "t"]);

    // A decoy beside the git directory, executable and announcing itself.
    let decoy = outside.join(".agents/skills/growth-guards/scripts");
    std::fs::create_dir_all(&decoy).unwrap();
    let marker = home.join("decoy-ran");
    for lane in ["pre-commit", "commit-msg", "install-git-hooks"] {
        let path = decoy.join(lane);
        std::fs::write(
            &path,
            format!("#!/bin/sh\ntouch {}\nexit 0\n", marker.display()),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    // The checkout itself carries nothing, which is the state a linked
    // worktree is in — so the decoy is the only copy any search could reach.
    let out = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert!(
        !marker.exists(),
        "a package beside the external git dir was executed as this \
         repository's gate: {}",
        said(&out)
    );
    assert_eq!(
        out.status.code(),
        Some(2),
        "finding no package is a refusal, not a pass: {}",
        said(&out)
    );
}
