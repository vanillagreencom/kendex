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
    REPO, World, commit, declare, declared_rev, fetch_mirrors, installed_body, locked_commit,
    sync_and_apply, world, write_agent, write_manifest, write_skill,
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

#[allow(clippy::unwrap_used)]
fn manifest_text(w: &World) -> String {
    fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap()
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

/// A schema line the surgical rewriter can touch writes the upgrade as a
/// text edit. That edit is compared against the manifest the plan computed
/// — so a plan carrying synthetic holds could never reproduce it, fell
/// back to a full serialize, and wrote every sibling's hold into the file
/// as if the person had chosen it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_surgical_schema_upgrade_writes_no_synthetic_hold() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    let first = commit(&w.upstream, "one");
    let body = "[skills.a]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n";
    declare(&w, body);
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    // A plain schema assignment, which `rewrite_schema_line` rewrites in
    // place — and the note beside it proves only those bytes changed.
    write_manifest(
        &w,
        &format!(
            "# The note this person wrote.\nschema = 4\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{body}"
        ),
    );

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap();
    assert!(
        matches!(manifest_op(&report), apply::Op::WriteFile { .. }),
        "the upgrade is a surgical edit; a full serialize means the plan could not reproduce it"
    );
    apply::execute(&w.env, &report.plan).unwrap();

    let text = manifest_text(&w);
    assert!(
        text.contains("# The note this person wrote."),
        "only the bytes it was about changed: {text}"
    );
    assert_eq!(
        declared_rev(&w, "b"),
        None,
        "the sibling held for this pass must not come back as a declared hold"
    );
    assert_eq!(locked_commit(&w, "a"), second);
    assert_eq!(locked_commit(&w, "b"), first);
}

/// The schema upgrade's fallback: a schema assignment the surgical
/// rewriter declines to touch serializes the whole manifest instead. The
/// bytes it serializes are the declared ones — the pass's synthetic holds
/// are not part of what the person wrote.
#[test]
#[allow(clippy::unwrap_used)]
fn a_schema_upgrade_fallback_writes_no_synthetic_hold() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    write_skill(&w.upstream, "b", "", "b version one.");
    let first = commit(&w.upstream, "one");
    let body = "[skills.a]\nsource = \"cat\"\n\n[skills.b]\nsource = \"cat\"\n";
    declare(&w, body);
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    // An older schema spelled with a quoted key: valid TOML that
    // `rewrite_schema_line` declines, which is what routes the upgrade
    // through the full serialize.
    write_manifest(
        &w,
        &format!(
            "\"schema\" = 4\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{body}"
        ),
    );

    let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap();
    assert!(
        matches!(manifest_op(&report), apply::Op::WriteManifest { .. }),
        "this schema line cannot be rewritten in place, so the plan serializes"
    );
    apply::execute(&w.env, &report.plan).unwrap();

    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert_eq!(
        loaded.schema,
        manifest::MANIFEST_SCHEMA,
        "the upgrade landed"
    );
    assert_eq!(
        loaded.declared(ItemKind::Skill)["b"].rev,
        None,
        "the sibling held for this pass must not come back as a declared hold"
    );
    assert_eq!(locked_commit(&w, "a"), second);
    assert_eq!(locked_commit(&w, "b"), first);
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

/// A v1 lock cannot be planned against, and this verb must say so: read as
/// "not installed", the scope falls through to the audit's observation-only
/// posture and every surface reports an update that never happened.
#[test]
#[allow(clippy::unwrap_used)]
fn a_v1_lock_refuses_a_single_package_update() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    let path = lock_path(&w.env, &w.scope);
    fs::write(
        &path,
        r#"{"version":1,"entries":{"a":{"name":"a","kind":"skill","source":"cat","source_repo":"owner/catalog","harnesses":["claude-code"],"method":"symlink","installed_at":"2026-01-01T00:00:00Z","source_hash":"abc"}}}"#,
    )
    .unwrap();

    let error = package::update_one(&w.env, &w.scope, ItemKind::Skill, "a").unwrap_err();
    assert!(matches!(error, CoreError::LegacyLock { .. }), "{error}");

    // A derived package has no declaration to be found either way, and the
    // lock is the only record that names it: the refusal must still be the
    // lock's, never the caller's spelling.
    let error = package::update_one(&w.env, &w.scope, ItemKind::Skill, "member").unwrap_err();
    assert!(matches!(error, CoreError::LegacyLock { .. }), "{error}");

    // And with the lock gone, a name the scope never had is the caller's
    // own mistake again.
    fs::remove_file(&path).unwrap();
    let error = package::update_one(&w.env, &w.scope, ItemKind::Skill, "stranger").unwrap_err();
    assert!(matches!(error, CoreError::NotDeclared { .. }), "{error}");
}

/// A v1 manifest is refused the same way — the arm the whole-scope audit
/// answers with a note, which this verb must not.
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
