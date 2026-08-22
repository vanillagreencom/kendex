//! Which exit a drift line names. Every line here is a fix a reader will
//! run, so a section is right only when the remedy beside it is the one
//! that works — an exit named where it would refuse is worse than none.

use super::tests::{
    env_in, manifest_with_remote, package, project_scope, snapshot_with, write_manifest,
};
use super::*;
use crate::drift::snapshot::PackageSnapshot;

#[test]
fn each_classification_lands_in_its_section_with_its_remedy() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(
        &env,
        &scope,
        vec![
            PackageSnapshot {
                update_available: true,
                ..package("stale-one")
            },
            PackageSnapshot {
                edited: true,
                ..package("edited-one")
            },
            PackageSnapshot {
                removed_upstream: true,
                ..package("gone-one")
            },
            PackageSnapshot {
                mixed: true,
                ..package("mixed-one")
            },
        ],
    );

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Drift);
    assert_eq!(report.status.exit_code(), 1);
    let text = render_plain(&report);
    assert!(text.contains("stale:"), "{text}");
    assert!(
        text.contains("'stale-one' has a newer version on its source — fix: kendex refresh"),
        "{text}"
    );
    assert!(
        text.contains("'edited-one'") && text.contains("fix: kendex fork skill edited-one"),
        "{text}"
    );
    assert!(
        text.contains("'gone-one'") && text.contains("fix: kendex remove gone-one"),
        "{text}"
    );
    assert!(
        text.contains("mixed installs:") && text.contains("'mixed-one'"),
        "{text}"
    );
    // Drift before suggestions: stale section renders before the age line.
    let stale_at = text.find("stale:").unwrap();
    let age_at = text.find("(checked against sources").unwrap();
    assert!(stale_at < age_at);
}

#[test]
fn edited_outranks_stale_for_one_package() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(
        &env,
        &scope,
        vec![PackageSnapshot {
            update_available: true,
            edited: true,
            ..package("both")
        }],
    );

    let text = render_plain(&check(&env, std::slice::from_ref(&scope)));
    assert!(text.contains("edited by hand:"), "{text}");
    assert!(!text.contains("stale:"), "one package, one line: {text}");
}

// The exit a report names has to be one that runs. A fork whose own copy
// can no longer be read back has none, and printing the discard would send
// a reader to a command that refuses while resolving that copy.
#[test]
fn an_edited_fork_with_no_readable_copy_names_no_exit() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(
        &env,
        &scope,
        vec![PackageSnapshot {
            edited: true,
            forked: true,
            can_discard: false,
            ..package("mine")
        }],
    );

    let text = render_plain(&check(&env, std::slice::from_ref(&scope)));
    assert!(text.contains("'mine'"), "{text}");
    assert!(text.contains("can no longer be read back"), "{text}");
    assert!(!text.contains("discard-edits"), "{text}");
}

// The control: the same fork with its copy intact keeps the exit — and the
// exit is this package's, not the scope's. `refresh --discard-edits` takes
// every hand-edited package in the scope with it, so printing it as the fix
// for one line spends the others' edits on this one.
#[test]
fn an_edited_fork_with_its_copy_intact_names_the_discard() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(
        &env,
        &scope,
        vec![PackageSnapshot {
            edited: true,
            forked: true,
            ..package("mine")
        }],
    );

    let text = render_plain(&check(&env, std::slice::from_ref(&scope)));
    assert!(text.contains("kendex discard-edits skill mine"), "{text}");
    assert!(!text.contains("refresh --discard-edits"), "{text}");
}

/// A package installed because something else needs it has no declaration
/// of its own, and `fork` refuses one for that reason. A line naming
/// forking as its exit names one that will not run.
#[test]
fn an_edited_derived_package_is_offered_the_discard_it_can_take() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(
        &env,
        &scope,
        vec![PackageSnapshot {
            edited: true,
            derived: true,
            ..package("carried-one")
        }],
    );

    let text = render_plain(&check(&env, std::slice::from_ref(&scope)));
    assert!(
        !text.contains("kendex fork"),
        "it names an exit that refuses: {text}"
    );
    assert!(
        text.contains("fix: kendex discard-edits skill carried-one"),
        "and not the one it can take: {text}"
    );
    assert!(
        text.contains("came with something else"),
        "the line has to say why forking is not offered: {text}"
    );
}

/// Carried by something else and no longer offered by it: there is no
/// declaration to fork under, and nothing to render over the edit either.
/// Both exits refuse, so the line names neither.
#[test]
fn an_edited_derived_package_its_source_dropped_is_offered_no_exit() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(
        &env,
        &scope,
        vec![PackageSnapshot {
            edited: true,
            derived: true,
            can_discard: false,
            ..package("dropped-one")
        }],
    );

    let text = render_plain(&check(&env, std::slice::from_ref(&scope)));
    assert!(text.contains("'dropped-one'"), "{text}");
    assert!(
        !text.contains("kendex discard-edits skill dropped-one"),
        "it names an exit that refuses: {text}"
    );
    assert!(!text.contains("kendex fork"), "{text}");
    assert!(
        text.contains("no longer offers it"),
        "the line has to say why nothing is offered: {text}"
    );
}
