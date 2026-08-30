//! Updating one package within a scope: the target comes current while
//! every sibling follower stays at the commit its lock records. The
//! whole-scope apply — what `refresh` runs — is the unchanged control that
//! still brings everything current at once.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{PlanOptions, plan_refresh};
use kendex_core::error::CoreError;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest;
use kendex_core::model::ItemKind;
use kendex_core::package;

use super::{
    commit, declare, fetch_mirrors, installed_body, locked_commit, sync_and_apply, world,
    write_agent, write_manifest, write_skill,
};

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
    apply::execute(&w.env, &report.plan).unwrap();

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
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(installed_body(&w, "b").contains("b version two."));
    assert_eq!(locked_commit(&w, "b"), second);
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
        &PlanOptions::for_packages([(ItemKind::Skill, "a".to_owned())]),
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

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

/// The one manifest write a plan carries, whichever op shape it took.
#[allow(clippy::expect_used)]
fn manifest_op(report: &kendex_core::engine::EngineReport) -> &apply::Op {
    let path = "kendex.toml";
    let op = report
        .plan
        .ops
        .iter()
        .find(|op| match &op.op {
            apply::Op::WriteManifest { .. } => true,
            apply::Op::WriteFile { path: at, .. } => at.ends_with(path),
            _ => false,
        })
        .expect("the plan writes the manifest");
    &op.op
}

/// The write a plan makes on its own account — an agent whose upstream
/// skill list grew — serializes the manifest the pass computed, and that
/// one is a copy of the pinned planning manifest. The pins come back out
/// before it is written.
#[test]
#[allow(clippy::unwrap_used)]
fn a_manifest_the_pass_updated_writes_no_synthetic_hold() {
    let w = world();
    write_skill(&w.upstream, "gh", "", "gh version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    write_agent(&w.upstream, "rust", "Rust body.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[agents.rust]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n\n[agent-skills]\nrust = [\"gh\"]\n",
    );
    sync_and_apply(&w);

    // Upstream gives the agent a skill it did not have: the addition
    // merges back into `[agent-skills]`, which is the manifest write.
    write_skill(&w.upstream, "rust-perf", "", "perf version one.");
    write_skill(&w.upstream, "b", "", "b version two.");
    commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = package::update_one(&w.env, &w.scope, ItemKind::Agent, "rust").unwrap();
    assert!(
        matches!(manifest_op(&report), apply::Op::WriteManifest { .. }),
        "the merged skill list is a full manifest write"
    );
    apply::execute(&w.env, &report.plan).unwrap();

    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert!(
        loaded.agent_skills["rust"].contains(&"rust-perf".to_owned()),
        "the write this test is about actually happened: {:?}",
        loaded.agent_skills
    );
    assert_eq!(
        loaded.declared(ItemKind::Skill)["b"].rev,
        None,
        "the sibling held for this pass must not come back as a declared hold"
    );
    assert!(
        installed_body(&w, "b").contains("b version one."),
        "and the sibling did not move"
    );
    assert_eq!(locked_commit(&w, "b"), first);
}

/// `kendex pin` scopes its plan to the package it names, the same way the
/// app's hold move does — the CLI's own coverage of that claim is the
/// end-to-end test in the cli crate; this is the option shape it builds.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hold_move_scoped_by_for_package_leaves_the_siblings_alone() {
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

    let report = package::set_rev_with(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "a",
        Some(&second),
        &PlanOptions::for_package(ItemKind::Skill, "a"),
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "a").contains("a version two."));
    assert!(
        installed_body(&w, "b").contains("b version one."),
        "a hold move from the command line must not bring the scope's followers current"
    );
    assert_eq!(locked_commit(&w, "b"), first);
}

/// A v1 manifest is refused by name rather than read as "declares
/// nothing", which would answer this targeted verb with an empty plan.
#[test]
#[allow(clippy::unwrap_used)]
fn a_v1_manifest_refuses_a_single_package_update() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    write_manifest(&w, "[skills.a]\nsource = \"cat\"\n");
    let error = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap_err();
    assert!(matches!(error, CoreError::LegacyManifest { .. }), "{error}");
}

/// The package page's discard: the catalog's version wins for this package
/// and nothing else. Both halves are scoped to the one package — the edits
/// discarded and the version brought current — so a neighbour keeps its
/// edits and the scope's other followers keep their commits.
#[test]
#[allow(clippy::unwrap_used)]
fn discarding_one_packages_edits_moves_that_package_alone() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.a]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    let installed = |name: &str| {
        w.home
            .join("app/.agents/skills")
            .join(name)
            .join("SKILL.md")
    };
    fs::write(installed("a"), "my own a.").unwrap();
    fs::write(installed("b"), "my own b.").unwrap();

    write_skill(&w.upstream, "a", "", "a version two.");
    write_skill(&w.upstream, "b", "", "b version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    let report = kendex_core::engine::plan_scope(
        &w.env,
        &w.scope,
        &loaded,
        &lock,
        &PlanOptions::for_package_discarding_edits(ItemKind::Skill, "a"),
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        installed_body(&w, "a").contains("a version two."),
        "the target's edits are discarded and it comes current"
    );
    assert_eq!(
        fs::read_to_string(installed("b")).unwrap(),
        "my own b.",
        "a neighbour's edits are not discarded along with the target's"
    );
    assert_eq!(locked_commit(&w, "a"), second);
    assert_eq!(
        locked_commit(&w, "b"),
        first,
        "and the scope's other followers stay at their installed commits"
    );
}
