//! Which project a session-start remedy tells a reader to write, when the
//! project it is reporting on is a linked git worktree.
//!
//! A project-scope kendex write from a linked worktree is refused unless
//! the command names the checkout it lands in, so a report printing the
//! bare verb there prints a command the reader cannot run. The check
//! resolves that name once and every remedy in the report carries it.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::drift::report;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use kendex_core::process::Hardened;

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A repository with one commit and one linked worktree beside it, under a
/// fixture home nothing else reaches.
#[allow(clippy::unwrap_used)]
fn repository() -> (tempfile::TempDir, Env, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let main = home.join("app");
    fs::create_dir_all(main.join(".claude")).unwrap();
    git(&main, &["init", "--quiet", "-b", "main"]);
    git(&main, &["add", "-A"]);
    git(
        &main,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "one",
        ],
    );
    let linked = home.join("lanes/one");
    git(
        &main,
        &[
            "worktree",
            "add",
            "--quiet",
            "-b",
            "lane",
            linked.to_str().unwrap(),
        ],
    );
    let linked = linked.canonicalize().unwrap();
    (tmp, Env::fake(&home, FakeOs::Linux), main, linked)
}

#[allow(clippy::unwrap_used)]
fn scope(root: &Path) -> Scope {
    Scope::Project {
        root: kendex_core::paths::canonical(root).unwrap(),
    }
}

#[allow(clippy::unwrap_used)]
fn declare(env: &Env, scope: &Scope) {
    let path = kendex_core::manifest::manifest_path(env, scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
    )
    .unwrap();
}

/// The three answers, over the one question every remedy in a report is
/// rendered against.
///
/// A worktree that declares packages of its own is a project in its own
/// right, and its own path is what a write must name. One that declares
/// nothing is a checkout of somebody else's manifest, and the checkout
/// that holds that manifest is what a write must name instead. The main
/// checkout needs no name at all, which is the inverse: a flag appearing
/// there would send every ordinary project's remedy through a path.
#[test]
#[allow(clippy::unwrap_used)]
fn the_remedy_target_is_the_worktree_that_declares_and_the_main_checkout_that_holds_the_manifest() {
    let (_tmp, env, main, linked) = repository();

    declare(&env, &scope(&main));
    let checked = report::check(&env, &[scope(&linked)]);
    assert_eq!(
        checked.project_target.as_deref(),
        Some(kendex_core::paths::canonical(&main).unwrap().as_path()),
        "a worktree with no manifest of its own points at the checkout that has one"
    );

    declare(&env, &scope(&linked));
    let checked = report::check(&env, &[scope(&linked)]);
    assert_eq!(
        checked.project_target.as_deref(),
        Some(kendex_core::paths::canonical(&linked).unwrap().as_path()),
        "a worktree that declares its own packages is the project a write names"
    );

    let checked = report::check(&env, &[scope(&main)]);
    assert_eq!(
        checked.project_target, None,
        "the main checkout is reached by a command typed in it and names nothing"
    );

    let checked = report::check(&env, &[Scope::Global]);
    assert_eq!(
        checked.project_target, None,
        "the personal scope is not a project and has no path to name"
    );
}

/// What the reader actually reads. The target is only useful if it reaches
/// the rendered command, and a report whose fix cannot be run where it is
/// printed is the defect this exists to end.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rendered_fix_inside_a_worktree_names_the_project_it_writes() {
    let (_tmp, env, _main, linked) = repository();
    let scope = scope(&linked);
    declare(&env, &scope);

    let mut checked = report::check(&env, std::slice::from_ref(&scope));
    // One drift line with the remedy the reached-by case reports: the
    // report's own sections depend on installed state, and what is under
    // test is the rendering of the target the check resolved.
    checked.sections = vec![report::Section {
        title: "stale".to_owned(),
        lines: vec![report::Line {
            class: report::Class::Drift,
            text: "'gh' does not match its source".to_owned(),
            remedy: Some(report::Remedy::Apply { global: false }),
        }],
    }];

    let text = report::render_plain(&checked);
    assert!(
        text.contains(&format!(
            "fix: kendex apply --project-path '{}'",
            kendex_core::paths::canonical(&linked).unwrap().display()
        )),
        "{text}"
    );
}
