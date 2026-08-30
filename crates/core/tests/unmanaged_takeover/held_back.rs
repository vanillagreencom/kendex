//! The scope-wide take-over on a mixed scope: an item with a place nothing
//! can settle has its take-over held back whole, and every other item
//! still gets its way out — one odd corner must not put the whole repo
//! back where it started.

use crate::test_util::source_path;

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{DriftState, PlanOptions, plan_apply};
use kendex_core::error::CoreError;
use kendex_core::model::ItemKind;

use crate::{World, foreign_install, take_over, trashed, world};

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

/// One item the sweep cannot settle must not take the way out from every
/// other item: the flag exists for a repo full of files some earlier tool
/// wrote, and such a repo arrives with the odd corner nothing can settle.
/// The odd item's take-over is held back whole — half of one would leave
/// the rest blocked with the files no longer theirs — and the plan says so.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dead_stop_on_one_item_holds_only_that_item_back() {
    let w = world();
    lint_in_catalog(&w);
    declare_tools(&w, "[\"claude\", \"codex\"]", BOTH_SKILLS);
    for name in ["deploy", "lint"] {
        let dir = w.home.join(format!("app/.claude/skills/{name}"));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("SKILL.md"), "the tool that came before").unwrap();
    }
    dead_stop_second_place(&w);

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        fs::read_to_string(w.home.join("app/.claude/skills/lint/SKILL.md"))
            .unwrap()
            .contains("Upstream."),
        "the item with nothing but files in the way was not replaced"
    );
    assert!(
        trashed(&w.env.trash_dir()),
        "the files that were in its way are recoverable"
    );
    assert_eq!(
        fs::read_to_string(w.home.join("app/.claude/skills/deploy/SKILL.md")).unwrap(),
        "the tool that came before",
        "half of the held-back item was taken over"
    );
    assert!(
        w.home.join("app/.agents/skills/deploy").is_symlink(),
        "the link is left exactly as it was"
    );
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "deploy" && row.state == DriftState::Conflict),
        "the held-back item no longer shows why it is blocked: {:?}",
        report.drift
    );
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("skill deploy was not replaced")
                && note.contains("the files in its way stay")),
        "the plan does not say what it held back: {:?}",
        report.notes
    );
}

/// Held back is the take-over, not the item: a place of the held item
/// with nothing in the way is installed exactly as a run without the flag
/// would install it, while the files in its way stay put — so the note
/// promises only that.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_item_s_empty_place_is_still_installed() {
    let w = world();
    lint_in_catalog(&w);
    declare_tools(&w, "[\"claude\", \"codex\", \"opencode\"]", BOTH_SKILLS);
    let dir = foreign_install(&w);
    dead_stop_second_place(&w);
    let lint = w.home.join("app/.agents/skills/lint");
    fs::create_dir_all(&lint).unwrap();
    fs::write(lint.join("SKILL.md"), "the tool that came before").unwrap();

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        fs::read_to_string(w.home.join("app/.opencode/skills/deploy/SKILL.md"))
            .unwrap()
            .contains("Upstream."),
        "the held item's empty place was left empty"
    );
    assert!(
        fs::read_to_string(dir.join("SKILL.md"))
            .unwrap()
            .contains("came before"),
        "the files in the held item's way were replaced"
    );
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("skill deploy was not replaced")),
        "{:?}",
        report.notes
    );
}

/// The same mixed scope in the linking layout. lint's take-over is staged
/// on its canonical tree and its harness link is planned after it — the
/// row the sweep reads must still say the item was swept, or the one
/// settleable item goes unseen and the run refuses over deploy alone.
#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_item_s_take_over_still_counts_as_settled() {
    let w = world();
    lint_in_catalog(&w);
    for name in ["deploy", "lint"] {
        let dir = w.home.join(format!("app/.agents/skills/{name}"));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("SKILL.md"), "the tool that came before").unwrap();
    }
    fs::write(
        w.home.join("app/kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.deploy]\nsource = \"cat\"\nharnesses = [\"claude\", \"codex\"]\n\n[skills.lint]\nsource = \"cat\"\n",
            source_path(&w.home.join("catalog"))
        ),
    )
    .unwrap();
    // deploy's claude place: a link at a folder that is no skill at all.
    let elsewhere = w.home.join("documents");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::write(elsewhere.join("notes.txt"), "private").unwrap();
    let link = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &link).unwrap();

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        fs::read_to_string(w.home.join("app/.agents/skills/lint/SKILL.md"))
            .unwrap()
            .contains("Upstream."),
        "the linked item's take-over was not carried out"
    );
    assert!(
        w.home.join("app/.claude/skills/lint").is_symlink(),
        "and its tool is connected to the tree"
    );
    assert_eq!(
        fs::read_to_string(w.home.join("app/.agents/skills/deploy/SKILL.md")).unwrap(),
        "the tool that came before",
        "half of the held-back item was taken over"
    );
    assert!(link.is_symlink(), "the link is left exactly as it was");
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("deploy") && note.contains("not replaced")),
        "the plan does not say what it held back: {:?}",
        report.notes
    );
}

/// Under the flag, the row that holds an item back is the only place its
/// dead stop shows: without it the files in the way are refused before
/// the link beside them is looked at. So the note, and the refusal when
/// every item is held, carry the place that holds it — or the reader is
/// sent round a loop with the cause named nowhere.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_item_is_named_with_the_place_that_holds_it() {
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

    declare(BOTH_SKILLS);
    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    let note = report
        .notes
        .iter()
        .find(|note| note.contains("skill deploy was not replaced"))
        .unwrap_or_else(|| panic!("{:?}", report.notes));
    assert!(
        names_the_link(note),
        "the note does not say what holds it: {note}"
    );

    declare("[skills.deploy]\nsource = \"cat\"\n");
    let refused = plan_apply(&w.env, &w.scope, &take_over());
    let Err(error) = refused else {
        panic!("{refused:?}");
    };
    assert!(
        matches!(&error, CoreError::TakeOverAllHeld { .. }),
        "{error:?}"
    );
    let said = error.to_string();
    assert!(
        names_the_link(&said),
        "the refusal does not say what holds it: {said}"
    );
    assert!(!said.contains("--plan"), "sent round the loop: {said}");
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
        matches!(&error, CoreError::TakeOverAllHeld { held } if held.len() == 1 && held[0].starts_with("skill deploy — ")),
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
