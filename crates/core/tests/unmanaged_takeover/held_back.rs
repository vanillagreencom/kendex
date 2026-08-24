//! The scope-wide take-over on a mixed scope: an item with a place nothing
//! can settle is held back whole, and every other item still gets its way
//! out — one odd corner must not put the whole repo back where it started.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{DriftState, plan_apply};

use crate::{World, foreign_install, take_over, trashed, world};

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

/// Declare for two tools, keeping the copy method the fixture plans with.
#[allow(clippy::unwrap_used)]
fn declare_both_tools(w: &World, skills: &str) {
    fs::write(
        w.home.join("app/kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n\n{skills}",
            w.home.join("catalog").display()
        ),
    )
    .unwrap();
}

/// One item the sweep cannot settle must not take the way out from every
/// other item: the flag exists for a repo full of files some earlier tool
/// wrote, and such a repo arrives with the odd corner nothing can settle.
/// The odd item is held back whole — half a take-over would leave the rest
/// blocked with the files no longer theirs — and the plan says so.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dead_stop_on_one_item_holds_only_that_item_back() {
    let w = world();
    let lint = w.home.join("catalog/skills/lint");
    fs::create_dir_all(&lint).unwrap();
    fs::write(
        lint.join("SKILL.md"),
        "---\nname: lint\ndescription: tidy it\n---\nUpstream.\n",
    )
    .unwrap();
    declare_both_tools(
        &w,
        "[skills.deploy]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
    );
    for name in ["deploy", "lint"] {
        let dir = w.home.join(format!("app/.claude/skills/{name}"));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("SKILL.md"), "the tool that came before").unwrap();
    }
    dead_stop_second_place(&w);

    let report = plan_apply(&w.env, &w.scope, &take_over()).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

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
            .any(|note| note.contains("deploy") && note.contains("not replaced")),
        "the plan does not say what it held back: {:?}",
        report.notes
    );
}

/// With nothing the sweep can settle, replacing nothing and reporting
/// success would be a lie — the run refuses and changes nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_sweep_that_can_replace_nothing_refuses() {
    let w = world();
    declare_both_tools(&w, "[skills.deploy]\nsource = \"cat\"\n");
    let dir = foreign_install(&w);
    dead_stop_second_place(&w);

    let refused = plan_apply(&w.env, &w.scope, &take_over());
    assert!(
        matches!(refused, Err(kendex_core::error::CoreError::TakeOverAllHeld)),
        "a sweep with nothing to do did not say so: {refused:?}"
    );
    assert!(
        fs::read_to_string(dir.join("SKILL.md"))
            .unwrap()
            .contains("came before"),
        "and the files in the way stay where they are"
    );
}
