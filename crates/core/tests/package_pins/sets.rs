//! A package a set carries, and what decides the revision it reads.
//!
//! A set carries one revision to everything in it. Declare one of those
//! packages outright and there are two readings of its revision to
//! reconcile — and a single-package update, which pins the rest of the
//! scope still to hold it there, adds a third that nobody wrote.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{DriftState, audit};
use kendex_core::error::CoreError;
use kendex_core::lock::{LOCK_VERSION, load as load_lock, lock_path};
use kendex_core::manifest;
use kendex_core::model::ItemKind;
use kendex_core::package;

use super::{
    World, commit, declare, declared_rev, fetch_mirrors, installed_body, locked_commit,
    sync_and_apply, world, write_skill,
};

/// What the plan says this package is wanted at, as the person reads it.
fn rev_conflict_message(report: &kendex_core::engine::EngineReport, name: &str) -> String {
    report
        .warnings
        .iter()
        .find(|w| w.name == name && w.message.contains("wanted at"))
        .map(|w| w.message.clone())
        .unwrap_or_default()
}

#[test]
#[allow(clippy::unwrap_used)]
fn updating_a_bundle_member_moves_its_bundle_and_no_one_else() {
    let w = world();
    write_skill(&w.upstream, "m1", "", "m1 version one.");
    write_skill(&w.upstream, "m2", "", "m2 version one.");
    write_skill(&w.upstream, "solo", "", "solo version one.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"m1\", \"m2\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.solo]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "m1", "", "m1 version two.");
    write_skill(&w.upstream, "m2", "", "m2 version two.");
    write_skill(&w.upstream, "solo", "", "solo version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    // The member has no declaration of its own — the bundle is what
    // carries its revision, so updating the member moves the bundle.
    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "m1").unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "m1").contains("m1 version two."));
    assert!(
        installed_body(&w, "m2").contains("m2 version two."),
        "a fellow member shares the bundle's one revision"
    );
    assert!(
        installed_body(&w, "solo").contains("solo version one."),
        "a follower outside the bundle stays put"
    );
    assert_eq!(locked_commit(&w, "m1"), second);
    assert_eq!(locked_commit(&w, "solo"), first);
}

/// A world whose catalog carries a set of `a` and `b`, with `a` declared
/// outright as well: the scope that has two readings of one package's
/// revision to reconcile. Returns the commit everything is installed from
/// and the one upstream moved to.
#[allow(clippy::unwrap_used)]
fn a_declared_member_of_a_set(w: &World, also_declared: &str) -> (String, String) {
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    write_skill(&w.upstream, "solo", "", "solo version one.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"a\", \"b\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(w, also_declared);
    sync_and_apply(w);

    write_skill(&w.upstream, "a", "", "a version two.");
    write_skill(&w.upstream, "b", "", "b version two.");
    write_skill(&w.upstream, "solo", "", "solo version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(w);
    (first, second)
}

/// Whether the plan reports this package as wanted at two revisions at
/// once — the conflict that writes nothing and asks the person to
/// reconcile pins.
fn reports_a_rev_conflict(report: &kendex_core::engine::EngineReport, name: &str) -> bool {
    report
        .drift
        .iter()
        .any(|row| row.name == name && row.state == DriftState::Conflict)
        || report
            .warnings
            .iter()
            .any(|w| w.name == name && w.message.contains("wanted at"))
}

/// A package the person declared and a set also carries has two readings
/// of its revision. Their own declaration is the one they acted on, so it
/// decides: the package moves, and the set stays where its record says it
/// is with every other member still on it.
#[test]
#[allow(clippy::unwrap_used)]
fn updating_a_declared_package_a_set_also_carries_moves_it_alone() {
    let w = world();
    let (first, second) = a_declared_member_of_a_set(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap();
    assert!(
        !reports_a_rev_conflict(&report, "a"),
        "the declaration and the set's hold are both this pass's reading, not a conflict the person made: {:?}",
        report.warnings
    );
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "a").contains("a version two."));
    assert!(
        installed_body(&w, "b").contains("b version one."),
        "a fellow member of the set must not come current as a side effect"
    );
    assert_eq!(locked_commit(&w, "a"), second);
    assert_eq!(
        locked_commit(&w, "b"),
        first,
        "the set stays at the commit its record says it is on"
    );
    assert_eq!(
        declared_rev(&w, "a"),
        None,
        "the target was never held, and nothing invented a hold for it"
    );
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert_eq!(
        loaded.bundles["kit"].rev, None,
        "the hold that held the set still for this pass is not a hold the person chose"
    );
}

/// The scope the update above leaves behind: the set's members sit on two
/// commits, and the declared one is the record for where it is. Moving the
/// other member reads it that way instead of pinning it through the set
/// again and refusing to write either revision.
#[test]
#[allow(clippy::unwrap_used)]
fn moving_the_rest_of_the_set_afterwards_leaves_the_declared_member_put() {
    let w = world();
    let (_, second) = a_declared_member_of_a_set(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    // `b` has no declaration of its own, so the set is what carries its
    // revision and moving it moves the set.
    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "b").unwrap();
    assert!(
        !reports_a_rev_conflict(&report, "a"),
        "the declared member is read off its own declaration, not pinned through the set twice: {:?}",
        report.warnings
    );
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "b").contains("b version two."));
    assert!(installed_body(&w, "a").contains("a version two."));
    assert_eq!(locked_commit(&w, "a"), second);
    assert_eq!(locked_commit(&w, "b"), second);
}

/// The must-fail control: a set and a member pinned at different commits
/// is a disagreement the person wrote, and a single-package update
/// elsewhere in the scope still reports it and writes nothing for the
/// package it is about.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hold_the_person_wrote_against_their_set_still_conflicts() {
    let w = world();
    let (first, second) = a_declared_member_of_a_set(
        &w,
        "[skills.solo]\nsource = \"cat\"\n\n[skills.a]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );

    // The person pins the package one way and the set that carries it
    // another. Nothing invented either revision.
    declare(
        &w,
        &format!(
            "[skills.solo]\nsource = \"cat\"\n\n[skills.a]\nsource = \"cat\"\nrev = \"{second}\"\n\n[bundles.kit]\nsource = \"cat\"\nrev = \"{first}\"\n"
        ),
    );

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "solo").unwrap();
    assert!(
        reports_a_rev_conflict(&report, "a"),
        "two revisions the person pinned must still conflict: {:?}",
        report.drift
    );
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        installed_body(&w, "a").contains("a version one."),
        "nothing is written for a conflicted package"
    );
    assert_eq!(
        locked_commit(&w, "a"),
        first,
        "and its record is left exactly as it was"
    );
}
/// A set can reach a declared package through what requires it rather than
/// by carrying it. That set holds the parent's revision, not this
/// package's: held still, it carries its commit onto a package whose own
/// declaration reads fresh, and the update the person asked for reports a
/// conflict instead of happening.
#[test]
#[allow(clippy::unwrap_used)]
fn updating_a_package_a_set_reaches_through_a_parent_still_moves_it() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(
        &w.upstream,
        "parent",
        "dependencies:\n  required: [a]\n",
        "parent version one.",
    );
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"parent\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap();
    assert!(
        !reports_a_rev_conflict(&report, "a"),
        "the set owns what requires the package, not the package: {:?}",
        report.warnings
    );
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        installed_body(&w, "a").contains("a version two."),
        "the package the person named has to actually move"
    );
    assert_eq!(locked_commit(&w, "a"), second);
}

/// Once a declared member has moved on its own, the set's members sit on
/// two commits and the moved one is no longer evidence of where the set
/// is. Read as evidence it leaves the set placeable at no commit at all,
/// and the next update of anything else takes the set's undeclared members
/// current.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_that_moved_alone_no_longer_says_where_its_set_is() {
    let w = world();
    let (first, _) = a_declared_member_of_a_set(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.solo]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    write_skill(&w.upstream, "b", "", "b version three.");
    write_skill(&w.upstream, "solo", "", "solo version three.");
    let third = commit(&w.upstream, "three");
    fetch_mirrors(&w);

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "solo").unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "solo").contains("solo version three."));
    assert!(
        installed_body(&w, "b").contains("b version one."),
        "the set is still held where its own members say it is"
    );
    assert_eq!(locked_commit(&w, "b"), first);
    assert_eq!(locked_commit(&w, "solo"), third);
}

/// A set the person pinned by hand, carrying a member they declared with
/// no revision of its own, is a disagreement a whole-scope pass reports. A
/// single-package update elsewhere holds that member at the commit it is
/// installed from — and weighed against that invented pin, the person's
/// own pin reads as agreement and the conflict disappears.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_pinned_set_conflicts_with_a_member_this_pass_pinned() {
    let w = world();
    let (first, _) = a_declared_member_of_a_set(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.solo]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    // Pinned at the very commit the member is installed from, which is the
    // pin this pass would otherwise invent for it.
    declare(
        &w,
        &format!(
            "[skills.a]\nsource = \"cat\"\n\n[skills.solo]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\nrev = \"{first}\"\n"
        ),
    );

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "solo").unwrap();
    assert!(
        reports_a_rev_conflict(&report, "a"),
        "the set's pin is the person's and the member's declaration follows the source: {:?}",
        report.warnings
    );
    assert!(
        rev_conflict_message(&report, "a").contains("the source's own revision"),
        "the declaration follows the source, which is what it has to say: {}",
        rev_conflict_message(&report, "a")
    );
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        installed_body(&w, "solo").contains("solo version two."),
        "the package the person named still updates"
    );
    assert!(
        installed_body(&w, "a").contains("a version one."),
        "and nothing is written for the conflicted one"
    );
}

/// The same disagreement with the set pinned somewhere else again: the
/// warning has to name the revisions the person wrote, never the commit
/// this pass pinned the member at to hold the rest of the scope still.
#[test]
#[allow(clippy::unwrap_used)]
fn a_conflict_with_a_hand_pinned_set_names_no_invented_commit() {
    let w = world();
    let (first, second) = a_declared_member_of_a_set(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.solo]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    declare(
        &w,
        &format!(
            "[skills.a]\nsource = \"cat\"\n\n[skills.solo]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\nrev = \"{second}\"\n"
        ),
    );

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "solo").unwrap();
    let message = rev_conflict_message(&report, "a");
    assert!(
        message.contains("the source's own revision"),
        "the member's declaration follows the source: {message}"
    );
    assert!(
        !message.contains(&first[..7]),
        "the commit this pass pinned the member at is not one the person can act on: {message}"
    );
    assert!(
        message.contains(&second[..7]),
        "the set's own pin is: {message}"
    );
}

/// A set every one of whose members is also declared outright. Nothing is
/// installed here only as a member, so the set's own members are the only
/// installations that can say where it is held. Left saying nothing it
/// reads its source's tip, and an unrelated single-package update takes
/// whatever the catalog has added to the set since — a package nobody
/// asked for, installed by an update about something else.
#[test]
#[allow(clippy::unwrap_used)]
fn a_set_whose_members_are_all_declared_stays_where_it_is() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    write_skill(&w.upstream, "solo", "", "solo version one.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"a\", \"b\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n\n[skills.solo]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    // Upstream grows the set and moves the unrelated package.
    write_skill(&w.upstream, "c", "", "c version one.");
    write_skill(&w.upstream, "solo", "", "solo version two.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"a\", \"b\", \"c\"]\n",
    )
    .unwrap();
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "solo").unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "solo").contains("solo version two."));
    assert_eq!(locked_commit(&w, "solo"), second);

    assert!(
        !w.home.join("app/.agents/skills/c").exists(),
        "the set was read where it is installed, not at its source's tip: {:?}",
        report.plan.ops
    );
    assert!(installed_body(&w, "a").contains("a version one."));
    assert!(installed_body(&w, "b").contains("b version one."));
    assert_eq!(locked_commit(&w, "a"), first);
    assert_eq!(locked_commit(&w, "b"), first);

    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert_eq!(
        loaded.bundles["kit"].rev, None,
        "and the hold that held it still for this pass is not one the person chose"
    );
}

/// The same set, with the update aimed at one of its own members rather
/// than at an unrelated declaration. The target reads fresh and the set
/// has to be held — and the only installations that can say where it is
/// held are its declared members, the target's among them, whose commit is
/// the one about to move.
#[test]
#[allow(clippy::unwrap_used)]
fn updating_a_member_of_an_all_declared_set_leaves_the_set_where_it_is() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"a\", \"b\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    write_skill(&w.upstream, "b", "", "b version two.");
    write_skill(&w.upstream, "c", "", "c version one.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"a\", \"b\", \"c\"]\n",
    )
    .unwrap();
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        installed_body(&w, "a").contains("a version two."),
        "the package the person named has to actually move"
    );
    assert_eq!(locked_commit(&w, "a"), second);
    assert!(
        !w.home.join("app/.agents/skills/c").exists(),
        "the set was read where it is installed, not at its source's tip: {:?}",
        report.plan.ops
    );
    assert!(installed_body(&w, "b").contains("b version one."));
    assert_eq!(locked_commit(&w, "b"), first);

    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert_eq!(loaded.bundles["kit"].rev, None);
}

/// The scope a member moving alone leaves behind: the set's members sit at
/// two commits, so nothing they record agrees and no reading of them can
/// place the set. What the record says the set came out as still can, and
/// the next update of anything else holds it there rather than opening it
/// at its source's tip.
#[test]
#[allow(clippy::unwrap_used)]
fn a_set_whose_members_split_across_commits_still_holds() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"a\", \"b\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);
    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(
        locked_commit(&w, "a"),
        second,
        "the split this test is about"
    );
    assert_eq!(locked_commit(&w, "b"), first);

    // Upstream grows the set while the members are apart.
    write_skill(&w.upstream, "c", "", "c version one.");
    write_skill(&w.upstream, "b", "", "b version three.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"a\", \"b\", \"c\"]\n",
    )
    .unwrap();
    let third = commit(&w.upstream, "three");
    fetch_mirrors(&w);

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "b").unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        !w.home.join("app/.agents/skills/c").exists(),
        "the set is held where the record says it came out, not at its tip: {:?}",
        report.plan.ops
    );
    assert_eq!(locked_commit(&w, "b"), third, "the target still moves");
    assert_eq!(
        locked_commit(&w, "a"),
        second,
        "and the member that moved before stays where it moved to"
    );
}

/// One set carrying both a declared package and something that requires
/// it. The set owns the package two ways at once — it carries it, and it
/// owns the parent whose revision reaches it — and the second is the one
/// that decides: a set that owns a parent has to read fresh, or the parent
/// carries its commit onto a target whose own declaration reads fresh and
/// the update ends in a conflict without updating anything.
#[test]
#[allow(clippy::unwrap_used)]
fn updating_a_package_its_set_also_owns_through_a_parent_still_moves_it() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(
        &w.upstream,
        "parent",
        "dependencies:\n  required: [a]\n",
        "parent version one.",
    );
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"a\", \"parent\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap();
    assert!(
        !reports_a_rev_conflict(&report, "a"),
        "the set owns what requires the package as well as carrying it: {:?}",
        report.warnings
    );
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        installed_body(&w, "a").contains("a version two."),
        "the package the person named has to actually move"
    );
    assert_eq!(locked_commit(&w, "a"), second);
}

/// A record naming a version this build does not write is refused, in
/// both directions and for the same reason: a lock behind this format is
/// missing evidence this build reads, and one ahead of it holds evidence
/// this build would strip on its next write. Nothing converts either.
/// The lock here is otherwise exactly what this build writes, so the
/// version alone is what the refusal turns on.
#[test]
#[allow(clippy::unwrap_used)]
fn a_lock_naming_another_version_is_refused_in_both_directions() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    let path = lock_path(&w.env, &w.scope);
    assert_eq!(
        load_lock(&path).unwrap().version,
        LOCK_VERSION,
        "this build writes the current version"
    );
    // Written as text: `save` stamps the version it writes, which is the
    // whole point — only a hand-written or older-build record can name
    // another one.
    let current = fs::read_to_string(&path).unwrap();
    let renumber = |version: u32| {
        let stamped = format!("\"version\": {LOCK_VERSION}");
        let text = current.replace(&stamped, &format!("\"version\": {version}"));
        assert_ne!(text, current, "the version line must be the one rewritten");
        fs::write(&path, text).unwrap();
    };

    renumber(LOCK_VERSION - 1);
    let error = load_lock(&path).unwrap_err();
    assert!(matches!(error, CoreError::LockCorrupt { .. }), "{error}");
    assert!(error.to_string().contains("install fresh"), "{error}");
    assert!(
        audit(&w.env, &w.scope).is_err(),
        "and nothing plans past it"
    );

    renumber(LOCK_VERSION + 1);
    let error = load_lock(&path).unwrap_err();
    assert!(
        matches!(error, CoreError::SchemaTooNew { found, .. } if found == i64::from(LOCK_VERSION) + 1),
        "{error}"
    );
}
