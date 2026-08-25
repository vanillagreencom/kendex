//! Updating one package within a scope: the target comes current while
//! every sibling follower stays at the commit its lock records. The
//! whole-scope apply — what `refresh` runs — is the unchanged control that
//! still brings everything current at once.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{PlanOptions, plan_refresh};
use kendex_core::error::CoreError;
use kendex_core::lock::{entry_key, load as load_lock, lock_path};
use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind};
use kendex_core::{package, remote};

use super::{World, commit, declare, installed_body, sync_and_apply, world, write_skill};

#[allow(clippy::unwrap_used)]
fn fetch_mirrors(w: &World) {
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
}

#[allow(clippy::unwrap_used)]
fn locked_commit(w: &World, name: &str) -> String {
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    lock.entries[&entry_key(ItemKind::Skill, name, HarnessId::Claude)]
        .source_commit
        .clone()
        .unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn updating_one_follower_leaves_its_siblings_at_their_commits() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    write_skill(&w.upstream, "b", "", "b version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(installed_body(&w, "a").contains("a version two."));
    assert!(
        installed_body(&w, "b").contains("b version one."),
        "a sibling follower must not come current as a side effect"
    );
    assert_eq!(locked_commit(&w, "a"), second);
    assert_eq!(
        locked_commit(&w, "b"),
        first,
        "the sibling's record stays at the commit it is installed from"
    );

    // The whole-scope control: refresh is unchanged and brings the
    // sibling current.
    let report = plan_refresh(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(installed_body(&w, "b").contains("b version two."));
    assert_eq!(locked_commit(&w, "b"), second);
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
    apply::execute(&w.env, &report.plan, None).unwrap();

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

#[test]
#[allow(clippy::unwrap_used)]
fn moving_a_hold_leaves_the_scopes_followers_at_their_commits() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    write_skill(&w.upstream, "b", "", "b version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    // Pin `a` at the new commit — the Updates page's Update on a held
    // place. The plan is scoped to the package it names.
    let report = package::set_rev_with(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "a",
        Some(&second),
        &PlanOptions {
            update_only: Some((ItemKind::Skill, "a".to_owned())),
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(installed_body(&w, "a").contains("a version two."));
    assert!(
        installed_body(&w, "b").contains("b version one."),
        "moving one hold must not bring the scope's followers current"
    );
    assert_eq!(locked_commit(&w, "b"), first);
}

#[test]
#[allow(clippy::unwrap_used)]
fn updating_a_name_nothing_declares_or_records_is_refused() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    let error = package::update_one(&w.env, &w.scope, ItemKind::Skill, "stranger").unwrap_err();
    assert!(matches!(error, CoreError::NotDeclared { .. }), "{error}");
}
