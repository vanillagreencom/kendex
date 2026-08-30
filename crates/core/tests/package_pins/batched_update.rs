//! Updating several of a place's packages in one pass: every target comes
//! current, every follower nobody named holds, and the scope reconciles
//! once. The per-row path in `single_update` is the same verb with one
//! target, and stays the control for everything the batch must not change.

use std::fs;

use kendex_core::apply;
use kendex_core::error::CoreError;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest;
use kendex_core::model::ItemKind;
use kendex_core::package::{self, UpdateTarget};

use super::{
    commit, declare, declared_rev, fetch_mirrors, installed_body, locked_commit, sync_and_apply,
    world, write_skill,
};

/// A following place's row: it comes current on its declaration, with no
/// hold to move.
fn follows(name: &str) -> UpdateTarget {
    UpdateTarget {
        kind: ItemKind::Skill,
        name: name.to_owned(),
        hold: None,
    }
}

/// A held place's row: its Update moves the hold to `commit`.
fn held_at(name: &str, commit: &str) -> UpdateTarget {
    UpdateTarget {
        kind: ItemKind::Skill,
        name: name.to_owned(),
        hold: Some(commit.to_owned()),
    }
}

/// How many lock writes the plan carries. `Update all` over a place used
/// to cost one whole pass per row; the batch is one pass, and the lock is
/// written exactly once by every pass.
fn lock_writes(report: &kendex_core::engine::EngineReport) -> usize {
    report
        .plan
        .ops
        .iter()
        .filter(|op| matches!(op.op, apply::Op::WriteLock { .. }))
        .count()
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_place_of_followers_comes_current_in_one_pass() {
    let w = world();
    for name in ["a", "b", "c", "sibling"] {
        write_skill(&w.upstream, name, "", &format!("{name} version one."));
    }
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n\n[skills.c]\nsource = \"cat\"\n\n[skills.sibling]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    for name in ["a", "b", "c", "sibling"] {
        write_skill(&w.upstream, name, "", &format!("{name} version two."));
    }
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = package::update_many(
        &w.env,
        &w.scope,
        &[follows("a"), follows("b"), follows("c")],
    )
    .unwrap();
    assert_eq!(
        lock_writes(&report),
        1,
        "three rows are one reconcile and one record, not three of each"
    );
    apply::execute(&w.env, &report.plan).unwrap();

    for name in ["a", "b", "c"] {
        assert!(installed_body(&w, name).contains(&format!("{name} version two.")));
        assert_eq!(locked_commit(&w, name), second);
    }
    assert!(
        installed_body(&w, "sibling").contains("sibling version one."),
        "a follower nobody named must not come current as a side effect"
    );
    assert_eq!(locked_commit(&w, "sibling"), first);
    assert_eq!(
        declared_rev(&w, "sibling"),
        None,
        "and the hold that held it still for this pass is not one the person chose"
    );
}

/// The Updates page hands a place both kinds of row at once: a held one
/// whose Update moves its hold, and a following one that reads its
/// source's tip. Both belong to one plan, so the click costs the place one
/// apply either way.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hold_move_and_a_follow_travel_in_one_plan() {
    let w = world();
    write_skill(&w.upstream, "pinned", "", "pinned version one.");
    write_skill(&w.upstream, "free", "", "free version one.");
    write_skill(&w.upstream, "sibling", "", "sibling version one.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        &format!(
            "[skills.pinned]\nsource = \"cat\"\nrev = \"{first}\"\n\n[skills.free]\nsource = \"cat\"\n\n[skills.sibling]\nsource = \"cat\"\n"
        ),
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "pinned", "", "pinned version two.");
    write_skill(&w.upstream, "free", "", "free version two.");
    write_skill(&w.upstream, "sibling", "", "sibling version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = package::update_many(
        &w.env,
        &w.scope,
        &[held_at("pinned", &second), follows("free")],
    )
    .unwrap();
    assert_eq!(lock_writes(&report), 1);
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "pinned").contains("pinned version two."));
    assert!(installed_body(&w, "free").contains("free version two."));
    assert_eq!(
        declared_rev(&w, "pinned").as_deref(),
        Some(second.as_str()),
        "the hold moved in the manifest, which is what a held row's Update is"
    );
    assert_eq!(declared_rev(&w, "free"), None);
    assert!(
        installed_body(&w, "sibling").contains("sibling version one."),
        "and the place's other follower stayed where it is"
    );
    assert_eq!(locked_commit(&w, "sibling"), first);
}

/// Invariant 11 over a batch: every selector resolves before anything is
/// planned, so a target the source cannot place refuses the whole batch.
/// A batch that dropped the unresolvable row and planned the rest would
/// move the holds beside it while reporting nothing about the one that
/// failed.
#[test]
#[allow(clippy::unwrap_used)]
fn one_unresolvable_hold_leaves_the_whole_batch_unwritten() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        &format!(
            "[skills.a]\nsource = \"cat\"\nrev = \"{first}\"\n\n[skills.b]\nsource = \"cat\"\nrev = \"{first}\"\n"
        ),
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    write_skill(&w.upstream, "b", "", "b version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let before = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    let error = package::update_many(
        &w.env,
        &w.scope,
        &[held_at("a", &second), held_at("b", "no-such-tag")],
    )
    .unwrap_err();
    assert!(matches!(error, CoreError::PinUnavailable { .. }), "{error}");
    let after = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert_eq!(
        before, after,
        "a batch with one refused selector must move no hold at all"
    );
    assert_eq!(
        declared_rev(&w, "a").as_deref(),
        Some(first.as_str()),
        "the hold beside the refused one stayed exactly where it was"
    );
    assert!(installed_body(&w, "a").contains("a version one."));
}

/// A batch that names a package this scope neither declares nor records is
/// refused whole, on the name that is wrong — the same answer the
/// single-package verb gives, so a bad row never costs the place a pass.
#[test]
#[allow(clippy::unwrap_used)]
fn a_batch_naming_a_stranger_is_refused_whole() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    let first = commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let error =
        package::update_many(&w.env, &w.scope, &[follows("a"), follows("stranger")]).unwrap_err();
    assert!(matches!(error, CoreError::NotDeclared { .. }), "{error}");
    assert_eq!(
        locked_commit(&w, "a"),
        first,
        "and the target beside it did not move on the refused pass"
    );
}

/// The membership guarantee, under a batch. A set every one of whose
/// members is also declared has only its members to say where it is held,
/// and holding it is what keeps the pass from enumerating the set at its
/// source's tip — where a package the catalog has added since would
/// install itself, with a `MemberOf` entry, during an update about
/// something else.
///
/// Naming two of the set's own members changes only which declarations go
/// unpinned. The set stays held, because whether the sets that carry a
/// target own it is asked of each target on its own terms, and both of
/// these have a declaration of their own to read.
#[test]
#[allow(clippy::unwrap_used)]
fn a_batch_over_declared_members_leaves_the_sets_membership_alone() {
    let w = world();
    for name in ["a", "b", "spare"] {
        write_skill(&w.upstream, name, "", &format!("{name} version one."));
    }
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"a\", \"b\", \"spare\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n\n[skills.spare]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    // Upstream moves the members and grows the set.
    for name in ["a", "b", "spare"] {
        write_skill(&w.upstream, name, "", &format!("{name} version two."));
    }
    write_skill(&w.upstream, "newcomer", "", "newcomer version one.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"a\", \"b\", \"spare\", \"newcomer\"]\n",
    )
    .unwrap();
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = package::update_many(&w.env, &w.scope, &[follows("a"), follows("b")]).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "a").contains("a version two."));
    assert!(installed_body(&w, "b").contains("b version two."));
    assert_eq!(locked_commit(&w, "a"), second);
    assert_eq!(locked_commit(&w, "b"), second);

    // What the set reads is where it is installed, not its source's tip.
    assert!(
        !w.home.join("app/.agents/skills/newcomer").exists(),
        "a package the catalog added to the set since must not install: {:?}",
        report.plan.ops
    );
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    assert!(
        !lock
            .entries
            .values()
            .any(|entry| entry.name == "newcomer" || entry.name == "kit"),
        "and nothing records it as a member: {:?}",
        lock.entries.keys().collect::<Vec<_>>()
    );
    assert_eq!(
        lock.bundles["kit"].commit, first,
        "the record still says where the set came out as, so the next pass can hold it there"
    );

    // A member nobody named stayed on its own declaration at its commit.
    assert!(installed_body(&w, "spare").contains("spare version one."));
    assert_eq!(locked_commit(&w, "spare"), first);

    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert_eq!(
        loaded.bundles["kit"].rev, None,
        "and the hold that held the set still for this pass is not one the person chose"
    );
}

/// The other half of that rule: whether the sets carrying a target own it
/// is the target's own answer, not the batch's. A derived member has no
/// declaration to read, so the set that carries it has to read fresh for
/// it to move at all — even in a batch whose other target is declared and
/// keeps its sets held.
#[test]
#[allow(clippy::unwrap_used)]
fn a_derived_target_frees_its_set_even_beside_a_declared_one() {
    let w = world();
    write_skill(&w.upstream, "member", "", "member version one.");
    write_skill(&w.upstream, "solo", "", "solo version one.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"member\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.solo]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    assert_eq!(locked_commit(&w, "member"), first);

    write_skill(&w.upstream, "member", "", "member version two.");
    write_skill(&w.upstream, "solo", "", "solo version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    // `solo` is declared and answers "my sets keep holding"; `member` is
    // derived and answers "the set that carries me has to read fresh".
    // Asked once for the batch, one of the two answers decides for both
    // and the other target does not move.
    let report =
        package::update_many(&w.env, &w.scope, &[follows("solo"), follows("member")]).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "solo").contains("solo version two."));
    assert!(
        installed_body(&w, "member").contains("member version two."),
        "a derived target moves only when the set that carries it reads fresh"
    );
    assert_eq!(locked_commit(&w, "member"), second);
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    assert_eq!(
        lock.bundles["kit"].commit, second,
        "and the record says where the set came out as, so the next pass holds it there"
    );
}
