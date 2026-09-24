//! Which project a session-start remedy tells a reader to write, when the
//! project it is reporting on is a linked git worktree.
//!
//! A session running the catalog's `block-worktree-refresh` hook is
//! refused a project-scope kendex write from a linked worktree unless the
//! command names the checkout it lands in, so a report printing the bare
//! verb there prints a command that session cannot run. The check resolves
//! that name once and every remedy in the report carries it.
#![cfg(unix)]

use crate::test_util;
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

/// One drift line carrying a project remedy: an installation the record
/// names and disk does not hold.
///
/// Every case here is about the project such a remedy has to name, and a
/// report with no project remedy resolves no project at all — so the line
/// is the premise, not decoration.
#[allow(clippy::unwrap_used)]
fn record_a_missing_agent(env: &Env, scope: &Scope) {
    let entry = kendex_core::lock::LockEntry {
        name: "gh".to_owned(),
        kind: kendex_core::model::ItemKind::Agent,
        harness: kendex_core::model::HarnessId::Claude,
        source: "cat".to_owned(),
        source_repo: "local".to_owned(),
        source_hash: "0".repeat(64),
        source_commit: None,
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        reasons: std::collections::BTreeSet::new(),
        machine: None,
    };
    let key = kendex_core::lock::entry_key(
        kendex_core::model::ItemKind::Agent,
        "gh",
        kendex_core::model::HarnessId::Claude,
    );
    let lock = kendex_core::lock::Lock {
        version: kendex_core::lock::LOCK_VERSION,
        entries: std::collections::BTreeMap::from([(key, entry)]),
        ..Default::default()
    };
    let path = kendex_core::lock::lock_path(env, scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    kendex_core::lock::save(&path, &lock).unwrap();
}

/// A manifest file that is there and will not load — conflict markers
/// after a rebase, a schema this release does not read.
#[allow(clippy::unwrap_used)]
fn declare_unreadably(env: &Env, scope: &Scope) {
    let path = kendex_core::manifest::manifest_path(env, scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, "<<<<<<< HEAD\nschema = 6\n=======\nschema = 6\n").unwrap();
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
///
/// Each project scope carries one drift line with a project remedy, which
/// is the premise: a report with nothing to point anywhere resolves no
/// destination at all.
#[test]
#[allow(clippy::unwrap_used)]
fn the_remedy_target_is_the_worktree_that_declares_and_the_main_checkout_that_holds_the_manifest() {
    let (_tmp, env, main, linked) = repository();
    record_a_missing_agent(&env, &scope(&linked));
    record_a_missing_agent(&env, &scope(&main));

    declare(&env, &scope(&main));
    let checked = report::check(&env, &[scope(&linked)]);
    assert_eq!(
        checked.project_target.as_deref(),
        Some(kendex_core::paths::canonical(&main).unwrap().as_path()),
        "a worktree with no manifest of its own points at the checkout that has one"
    );
    assert!(
        report::render_plain(&checked).contains(
            "fix: kendex remove gh (no --project-path form; the block-worktree-refresh hook refuses this verb inside a linked worktree)"
        ),
        "an absent manifest retains the explicit elsewhere marker"
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
    record_a_missing_agent(&env, &scope);

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

/// A current manifest can still want the recorded name in another harness.
/// The preview names the linked worktree without choosing a write.
#[test]
#[allow(clippy::unwrap_used)]
fn record_cleanup_alone_names_the_linked_worktree_in_its_plan_command() {
    let (_tmp, env, _main, linked) = repository();
    let scope = scope(&linked);
    declare(&env, &scope);
    record_a_missing_agent(&env, &scope);

    let checked = report::check(&env, std::slice::from_ref(&scope));
    assert_eq!(
        checked
            .sections
            .iter()
            .map(|section| section.title.as_str())
            .collect::<Vec<_>>(),
        ["record cleanup needed"],
        "the stale record is the only reported drift: {:?}",
        checked.sections
    );

    let text = report::render_plain(&checked);
    assert!(
        text.contains(&format!(
            "see: kendex apply --plan --project-path '{}'",
            kendex_core::paths::canonical(&linked).unwrap().display()
        )),
        "{text}"
    );
}

/// A worktree whose own manifest will not load still names itself.
///
/// The broken declarations are this worktree's, and so are the drift lines
/// printed above the fix. Sending the reader to the main checkout there
/// would put one place's lines over another place's command, and the
/// could-not-check line for the manifest sits in the same report saying
/// which place the file is in.
#[test]
#[allow(clippy::unwrap_used)]
fn a_worktree_whose_manifest_will_not_load_names_itself() {
    let (_tmp, env, main, linked) = repository();
    declare(&env, &scope(&main));
    declare_unreadably(&env, &scope(&linked));
    record_a_missing_agent(&env, &scope(&linked));

    let checked = report::check(&env, &[scope(&linked)]);
    assert_eq!(
        checked.project_target.as_deref(),
        Some(kendex_core::paths::canonical(&linked).unwrap().as_path()),
        "the manifest that would not load is the worktree's own"
    );
    assert_ne!(
        checked.project_target.as_deref(),
        Some(kendex_core::paths::canonical(&main).unwrap().as_path()),
        "and never the checkout it was added from"
    );
}

/// A kendex project can sit below the git top level, so the destination
/// under the main checkout is the same place below it — not the checkout
/// itself, which is a different project or none.
///
/// The inverse is the second half: where nothing at that place is a
/// project root, there is no destination to name and the report says
/// none rather than one a write would be refused at.
#[test]
#[allow(clippy::unwrap_used)]
fn a_project_below_the_git_top_level_maps_onto_the_same_place_in_the_main_checkout() {
    let (_tmp, env, main, linked) = repository();
    for root in [main.join("app"), linked.join("app"), linked.join("lib")] {
        fs::create_dir_all(root.join(".claude")).unwrap();
    }

    let below = scope(&linked.join("app"));
    record_a_missing_agent(&env, &below);
    let checked = report::check(&env, &[below]);
    assert_eq!(
        checked.project_target.as_deref(),
        Some(
            kendex_core::paths::canonical(&main.join("app"))
                .unwrap()
                .as_path()
        ),
        "the project under the main checkout, not its top level"
    );

    let orphan = scope(&linked.join("lib"));
    record_a_missing_agent(&env, &orphan);
    let checked = report::check(&env, &[orphan]);
    assert_eq!(
        checked.project_target, None,
        "a place the main checkout holds no project at names nothing"
    );
}

/// A clean report resolves no destination, and resolving one is the only
/// thing in this check that asks git anything — so a session that starts
/// on a clean project spawns no git child for it.
///
/// The worktree declares a manifest of its own here, which is the case
/// that resolves to a path: a target in this report would be the
/// resolution having run.
#[test]
#[allow(clippy::unwrap_used)]
fn a_clean_report_resolves_no_destination() {
    let (_tmp, env, _main, linked) = repository();
    let scope = scope(&linked);
    declare(&env, &scope);

    let checked = report::check(&env, std::slice::from_ref(&scope));
    assert!(checked.is_clean(), "{:?}", checked.sections);
    assert_eq!(
        checked.project_target, None,
        "nothing would have printed it, so nothing went looking for it"
    );
}
