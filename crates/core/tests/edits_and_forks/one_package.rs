//! What a command naming one package may touch. Each of these plans the
//! whole scope carrying that package's permission, so what keeps them
//! honest is measured before the plan and restricted inside it.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{PlanOptions, plan_scope};
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest;
use kendex_core::model::ItemKind;

use super::{commit, declare, skill_file, sync_and_apply, world, write_skill};

// The one fact both discard exits rest on — the CLI's `discard-edits` and
// the app's targeted apply. Each plans the whole scope carrying a
// permission for one package, so this is what stands between "put this
// package back" and "run whatever the scope had waiting".
#[test]
#[allow(clippy::unwrap_used)]
fn edited_here_answers_for_the_package_asked_about() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream gh.");
    write_skill(&w.upstream, "lint", "Upstream lint.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    let edited = |name: &str| {
        kendex_core::engine::edited_here(&w.env, &w.scope, ItemKind::Skill, name).unwrap()
            == kendex_core::engine::EditedHere::Yes
    };

    assert!(!edited("gh"), "nothing edited yet");
    fs::write(skill_file(&w), "my gh edit").unwrap();
    assert!(edited("gh"), "the edit this exit is for");
    assert!(!edited("lint"), "a sibling's clean copy is not this edit");
    assert!(!edited("nope"), "nothing is declared by that name");
}

// A plan is always the scope's. `only_names` is what keeps a command that
// names one package from installing, updating and re-rendering the rest of
// the scope under it — while the records of those others carry forward, so
// the lock this plan writes still knows what is installed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plan_for_one_package_leaves_every_other_declaration_alone() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream gh.");
    write_skill(&w.upstream, "lint", "Upstream lint.");
    write_skill(&w.upstream, "notes", "Upstream notes.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    fs::write(skill_file(&w), "my gh edit").unwrap();
    // Work the scope has waiting that this command was not asked about.
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n\n[skills.notes]\nsource = \"cat\"\n",
    );

    let manifest = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    let one = (ItemKind::Skill, "gh".to_owned());
    let report = plan_scope(
        &w.env,
        &w.scope,
        &manifest,
        &lock,
        &PlanOptions {
            overwrite_edited_names: Some(vec![one.clone()]),
            only_names: Some(vec![one]),
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("Upstream gh."),
        "the package named came back"
    );
    assert!(
        !w.home.join("app/.agents/skills/notes/SKILL.md").exists(),
        "a package nobody asked about was installed"
    );
    let after = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    assert!(
        after.entries.values().any(|entry| entry.name == "lint"),
        "the record of an untouched install was dropped: {after:?}"
    );
}

/// The manifest records what an agent renders with, and upstream additions
/// are merged into it as a side effect of planning. A plan restricted to
/// one package renders nothing for anybody else, so it must not write
/// anybody else's additions either: a manifest that has gained a skill
/// nothing installed describes a machine that does not exist, and the next
/// pass reads it as intent.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plan_for_one_package_records_no_other_packages_additions() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream gh.");
    // An agent whose role takes every skill matching its name.
    let agents = w.upstream.join("agents");
    fs::create_dir_all(&agents).unwrap();
    fs::write(
        agents.join("rust.md"),
        "---\nname: rust\ndescription: Rust engineer\nrole: engineer\n---\nBody.\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[agents.rust]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    // The agent's skill list is recorded, which is what makes a later
    // upstream skill an addition rather than part of the original set.
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[agents.rust]\nsource = \"cat\"\n\n[agent-skills]\nrust = []\n",
    );
    sync_and_apply(&w);

    // Upstream gains a skill the agent will claim.
    write_skill(&w.upstream, "rust-perf", "Perf.");
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    kendex_core::remote::sync_sources(&w.env, &loaded).unwrap();

    let planned = |only: Option<Vec<(ItemKind, String)>>| {
        let manifest = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
            .unwrap()
            .unwrap();
        let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
        plan_scope(
            &w.env,
            &w.scope,
            &manifest,
            &lock,
            &PlanOptions {
                only_names: only,
                ..Default::default()
            },
        )
        .unwrap()
    };

    // The control: unrestricted, the addition is recorded and rendered.
    let all = planned(None);
    assert!(
        kendex_core::engine::persists_manifest(&all.plan.ops),
        "the merge is written back"
    );

    // Restricted to another package, the agent is not rendered — so its
    // addition is not written down either.
    let one = planned(Some(vec![(ItemKind::Skill, "gh".to_owned())]));
    apply::execute(&w.env, &one.plan, None).unwrap();

    let after = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert!(
        !after
            .agent_skills
            .get("rust")
            .is_some_and(|skills| skills.iter().any(|skill| skill == "rust-perf")),
        "the manifest gained a skill nothing installed: {after:?}"
    );
}

/// "One package" is the package and what it needs. A discard whose source
/// has since declared a required dependency restores the package; skipping
/// the dependency would leave it unable to run, and the command would say
/// it worked — worse than doing too much, because nobody is told.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plan_for_one_package_installs_what_that_package_requires() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream gh.");
    write_skill(&w.upstream, "lint", "Upstream lint.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    fs::write(skill_file(&w), "my gh edit").unwrap();

    // Upstream gives gh a dependency it did not have when it was installed.
    let gh = w.upstream.join("skills/gh/SKILL.md");
    fs::write(
        &gh,
        "---\nname: gh\ndescription: about gh\ndependencies:\n  required: [helper]\n---\nUpstream gh.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "helper", "Helper.");
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    kendex_core::remote::sync_sources(&w.env, &loaded).unwrap();

    let one = (ItemKind::Skill, "gh".to_owned());
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    let report = plan_scope(
        &w.env,
        &w.scope,
        &loaded,
        &lock,
        &PlanOptions {
            overwrite_edited_names: Some(vec![one.clone()]),
            only_names: Some(vec![one]),
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

    let helper = w.home.join("app/.agents/skills/helper/SKILL.md");
    assert!(
        helper.is_file(),
        "the package was restored without what it requires"
    );
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("Upstream gh."),
        "and the package itself came back"
    );
    // Still one package's worth of work: the sibling is untouched.
    assert_eq!(
        fs::read_to_string(w.home.join("app/.agents/skills/lint/SKILL.md")).unwrap(),
        fs::read_to_string(w.upstream.join("skills/lint/SKILL.md")).unwrap(),
    );
}
