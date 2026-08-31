//! The scope-wide take-over on a mixed scope: it answers for every item it
//! swept up or for none of them, so one item with a place nothing can
//! settle refuses the run and names what blocks it. Replacing the rest
//! would leave that item's blocked place in the way with the item no
//! longer its tool's.

use crate::test_util::source_path;

use std::fs;

use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::error::CoreError;
use kendex_core::model::ItemKind;

use crate::{World, foreign_install, take_over, world};

/// The app's per-row button: replace exactly this item, whole or not at all.
fn named(kind: ItemKind, name: &str) -> PlanOptions {
    PlanOptions {
        replace_unmanaged_names: Some(vec![(kind, name.into())]),
        ..PlanOptions::default()
    }
}

/// deploy's second place: a link at a folder that is no skill at all —
/// the conflict neither exit can settle, beside the files the take-over
/// could otherwise replace.
#[allow(clippy::unwrap_used)]
fn dead_stop_second_place(w: &World) {
    let elsewhere = w.home.join("documents");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::write(elsewhere.join("notes.txt"), "private").unwrap();
    let position = w.home.join("app/.agents/skills/deploy");
    fs::create_dir_all(position.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &position).unwrap();
}

/// Declare for these tools, keeping the copy method the fixture plans with.
#[allow(clippy::unwrap_used)]
fn declare_tools(w: &World, harnesses: &str, skills: &str) {
    fs::write(
        w.home.join("app/kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = {harnesses}\nmethod = \"copy\"\n\n{skills}",
            source_path(&w.home.join("catalog"))
        ),
    )
    .unwrap();
}

/// A second skill in the catalog, beside deploy.
#[allow(clippy::unwrap_used)]
fn lint_in_catalog(w: &World) {
    let lint = w.home.join("catalog/skills/lint");
    fs::create_dir_all(&lint).unwrap();
    fs::write(
        lint.join("SKILL.md"),
        "---\nname: lint\ndescription: tidy it\n---\nUpstream.\n",
    )
    .unwrap();
}

const BOTH_SKILLS: &str = "[skills.deploy]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n";

/// One item the sweep cannot settle stops the sweep: replacing the rest
/// would leave that item's blocked place in the way with the item no
/// longer its tool's. Under the flag, the row that holds it is the only
/// place its dead stop shows — without it the files in the way are
/// refused before the link beside them is looked at — so the refusal
/// carries the place that holds it, or the reader is sent round a loop
/// with the cause named nowhere.
#[test]
#[allow(clippy::unwrap_used)]
fn one_unsettleable_item_refuses_the_sweep_and_names_what_holds_it() {
    let w = world();
    lint_in_catalog(&w);
    for name in ["deploy", "lint"] {
        let dir = w.home.join(format!("app/.agents/skills/{name}"));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("SKILL.md"), "the tool that came before").unwrap();
    }
    let declare = |skills: &str| {
        fs::write(
            w.home.join("app/kendex.toml"),
            format!(
                "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"symlink\"\n\n{skills}",
                source_path(&w.home.join("catalog"))
            ),
        )
        .unwrap();
    };
    let elsewhere = w.home.join("documents");
    fs::create_dir_all(&elsewhere).unwrap();
    let link = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &link).unwrap();
    let names_the_link =
        |text: &str| text.contains("Claude") && text.contains(".claude/skills/deploy");

    // A second item the sweep could settle whole is no reason to carry on:
    // the run answers for every item it swept up, or for none of them.
    declare(BOTH_SKILLS);
    let refused = plan_apply(&w.env, &w.scope, &take_over());
    let Err(error) = refused else {
        panic!("{refused:?}");
    };
    assert!(
        matches!(&error, CoreError::TakeOverSweepBlocked { .. }),
        "{error:?}"
    );
    let said = error.to_string();
    assert!(
        names_the_link(&said),
        "the refusal does not say what holds it: {said}"
    );
    assert!(!said.contains("--plan"), "sent round the loop: {said}");
    assert_eq!(
        fs::read_to_string(w.home.join("app/.agents/skills/lint/SKILL.md")).unwrap(),
        "the tool that came before",
        "the item it could have settled was replaced anyway"
    );

    // And with only the blocked item declared, the same refusal.
    declare("[skills.deploy]\nsource = \"cat\"\n");
    let refused = plan_apply(&w.env, &w.scope, &take_over());
    assert!(
        matches!(refused, Err(CoreError::TakeOverSweepBlocked { .. })),
        "{refused:?}"
    );
}

/// The button was clicked on an item one of whose places nothing can
/// settle: replacing the rest would leave that place blocked with the
/// item no longer its tool's, so the whole run refuses.
#[test]
#[allow(clippy::unwrap_used)]
fn a_named_take_over_with_an_unsettleable_place_refuses() {
    let w = world();
    declare_tools(
        &w,
        "[\"claude\", \"codex\"]",
        "[skills.deploy]\nsource = \"cat\"\n",
    );
    let dir = foreign_install(&w);
    dead_stop_second_place(&w);

    let refused = plan_apply(&w.env, &w.scope, &named(ItemKind::Skill, "deploy"));
    assert!(
        matches!(
            &refused,
            Err(CoreError::TakeOverLeavesSome { name }) if name == "deploy"
        ),
        "half the item was approved: {refused:?}"
    );
    assert!(
        fs::read_to_string(dir.join("SKILL.md"))
            .unwrap()
            .contains("came before"),
        "and the files in the way stay where they are"
    );
}

/// The page a click comes from can be a minute old. A name with nothing
/// in the way any more answers a question already gone, and running the
/// scope's whole apply for it would report a success nobody chose.
#[test]
#[allow(clippy::unwrap_used)]
fn a_name_that_reaches_nothing_refuses() {
    let w = world();

    let refused = plan_apply(&w.env, &w.scope, &named(ItemKind::Skill, "deploy"));
    assert!(
        matches!(
            &refused,
            Err(CoreError::TakeOverMatchesNothing { name }) if name == "deploy"
        ),
        "a stale choice was carried out: {refused:?}"
    );
}

/// With nothing the sweep can settle, replacing nothing and reporting
/// success would be a lie — the run refuses, changes nothing, and names
/// what it held: with no plan to carry the notes, the error is the only
/// place the reader learns which items those were.
#[test]
#[allow(clippy::unwrap_used)]
fn a_sweep_that_can_replace_nothing_refuses() {
    let w = world();
    declare_tools(
        &w,
        "[\"claude\", \"codex\"]",
        "[skills.deploy]\nsource = \"cat\"\n",
    );
    let dir = foreign_install(&w);
    dead_stop_second_place(&w);

    let refused = plan_apply(&w.env, &w.scope, &take_over());
    let Err(error) = refused else {
        panic!("a sweep with nothing to do did not say so: {refused:?}");
    };
    assert!(
        matches!(&error, CoreError::TakeOverSweepBlocked { blocked } if blocked.len() == 1 && blocked[0].starts_with("skill deploy — ")),
        "{error:?}"
    );
    assert!(
        error.to_string().contains("skill deploy"),
        "the refusal names no item: {error}"
    );
    assert!(
        fs::read_to_string(dir.join("SKILL.md"))
            .unwrap()
            .contains("came before"),
        "and the files in the way stay where they are"
    );
}

/// An item swept up and then dropped is still an item the sweep swept up.
/// A tree stages its canonical take-over and only then meets the harness
/// link it cannot touch, so the refusal rolls that staged work back and
/// the item leaves nothing behind but its dead stop. Read from what
/// survived, the sweep sees a blocked item it never took and lets the run
/// replace everything else — the hold-back this engine no longer does,
/// arrived at by losing the evidence rather than by deciding to.
#[test]
#[allow(clippy::unwrap_used)]
fn an_item_rolled_back_after_its_take_over_still_refuses_the_sweep() {
    let w = world();
    lint_in_catalog(&w);
    // Symlink delivery, so the canonical tree and the harness position are
    // two places of one item and the second is only reached after the
    // first is staged.
    fs::write(
        w.home.join("app/kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{BOTH_SKILLS}",
            source_path(&w.home.join("catalog"))
        ),
    )
    .unwrap();
    // lint: a stranger's files at its canonical position, wholly replaceable.
    let lint = w.home.join("app/.agents/skills/lint");
    fs::create_dir_all(&lint).unwrap();
    fs::write(lint.join("SKILL.md"), "the tool that came before").unwrap();
    // deploy: the same, with a foreign link at the harness position.
    let deploy = w.home.join("app/.agents/skills/deploy");
    fs::create_dir_all(&deploy).unwrap();
    fs::write(deploy.join("SKILL.md"), "the tool that came before").unwrap();
    let elsewhere = w.home.join("documents");
    fs::create_dir_all(&elsewhere).unwrap();
    let link = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &link).unwrap();

    let refused = plan_apply(&w.env, &w.scope, &take_over());
    let Err(error) = refused else {
        panic!("the sweep replaced the rest and dropped the item it could not settle: {refused:?}");
    };
    assert!(
        matches!(&error, CoreError::TakeOverSweepBlocked { blocked }
            if blocked.len() == 1 && blocked[0].starts_with("skill deploy — ")),
        "{error:?}"
    );
    // Nothing was planned, so the neighbour it would have replaced is
    // exactly as it was.
    assert_eq!(
        fs::read_to_string(lint.join("SKILL.md")).unwrap(),
        "the tool that came before"
    );
}
