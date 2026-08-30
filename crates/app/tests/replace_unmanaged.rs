//! The app's answer to "files are already there": each row's two buttons
//! act on that row alone. Taking one over must never take a neighbour's
//! files with it — the page shows several blocked items at once, and a
//! click lands on the one a person is reading.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;

use kendex_app::audit::{replace_unmanaged, view};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: std::path::PathBuf,
}

/// Two declared skills, both with files already where they install.
#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let project = home.join("dev/app");
    let source = home.join("catalog");
    for name in ["deploy", "lint"] {
        fs::create_dir_all(source.join(format!("skills/{name}"))).unwrap();
        fs::write(
            source.join(format!("skills/{name}/SKILL.md")),
            format!("---\nname: {name}\ndescription: does {name}\n---\nUpstream.\n"),
        )
        .unwrap();
        let here = project.join(format!(".claude/skills/{name}"));
        fs::create_dir_all(&here).unwrap();
        fs::write(here.join("SKILL.md"), "the tool that came before").unwrap();
    }
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn body(f: &Fixture, name: &str) -> String {
    fs::read_to_string(f.project.join(format!(".claude/skills/{name}/SKILL.md"))).unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn taking_over_one_row_leaves_the_other_row_alone() {
    let f = fixture();
    let before = view(&f.env, &f.scope);
    assert_eq!(
        before
            .drift
            .iter()
            .filter(|row| row.cause == Some(kendex_core::engine::DriftCause::UnmanagedContent))
            .count(),
        2,
        "both rows are waiting on a person: {:?}",
        before.drift
    );

    let after = replace_unmanaged(&f.env, &f.scope, ItemKind::Skill, "deploy".into()).unwrap();

    assert!(body(&f, "deploy").contains("Upstream."));
    assert_eq!(
        body(&f, "lint"),
        "the tool that came before",
        "a neighbour's files were taken along"
    );
    let still_waiting: Vec<&str> = after
        .drift
        .iter()
        .filter(|row| row.cause == Some(kendex_core::engine::DriftCause::UnmanagedContent))
        .map(|row| row.name.as_str())
        .collect();
    assert_eq!(still_waiting, vec!["lint"], "{:?}", after.drift);
}

/// The page a click comes from can be a minute old. A choice that is no
/// longer on offer must not run the scope's apply anyway and report success
/// — the row it was made on is gone, and what would have been applied is
/// everything else.
#[test]
#[allow(clippy::unwrap_used)]
fn a_choice_that_is_no_longer_on_offer_changes_nothing() {
    let f = fixture();
    // Nothing at deploy's place any more: it installs like any other item.
    fs::remove_dir_all(f.project.join(".claude/skills/deploy")).unwrap();

    let refused = replace_unmanaged(&f.env, &f.scope, ItemKind::Skill, "deploy".into());
    assert!(refused.is_err(), "a stale choice was carried out");
    assert_eq!(
        body(&f, "lint"),
        "the tool that came before",
        "and the rest of the scope was not applied on the way past"
    );
    assert!(
        !f.project.join(".claude/skills/deploy/SKILL.md").exists(),
        "nothing was installed either"
    );
}

/// The page offers "keep these files" by asking core which kinds adoption
/// can take — never by keeping its own copy of the list. A command offered
/// that button reached a verb that refuses, on a screen whose whole job is
/// helping the reader pick between two ways out.
#[test]
#[allow(clippy::unwrap_used)]
fn the_page_is_told_which_kinds_can_be_kept() {
    let f = fixture();
    assert_eq!(
        view(&f.env, &f.scope).adoptable,
        vec![ItemKind::Agent, ItemKind::Skill, ItemKind::Hook],
    );
    let refused = kendex_core::engine::adopt::adopt(
        &f.env,
        &f.scope,
        ItemKind::Command,
        "ship",
        &[kendex_core::model::HarnessId::Claude],
    );
    assert!(
        refused.is_err(),
        "the list and what adoption actually takes have drifted apart"
    );
}

/// The take-over is an apply like any other, so it owes the scope the
/// migrations an apply owes it. Planned from a copy of the manifest that
/// had already been normalized in memory, an older schema looked current
/// and was written back unmigrated.
#[test]
#[allow(clippy::unwrap_used)]
fn an_older_schema_is_brought_forward_by_the_same_apply() {
    let f = fixture();
    let path = f.project.join("kendex.toml");
    let older = fs::read_to_string(&path).unwrap().replace(
        "schema = 6",
        &format!("schema = {}", kendex_core::manifest::MANIFEST_SCHEMA - 1),
    );
    fs::write(&path, older).unwrap();

    replace_unmanaged(&f.env, &f.scope, ItemKind::Skill, "deploy".into()).unwrap();

    assert!(body(&f, "deploy").contains("Upstream."));
    assert!(
        fs::read_to_string(&path).unwrap().contains(&format!(
            "schema = {}",
            kendex_core::manifest::MANIFEST_SCHEMA
        )),
        "the scope was written without the migration it was owed:\n{}",
        fs::read_to_string(&path).unwrap()
    );
}

/// The state the app has to answer for the hand-made sharing layout: the
/// row carries the folder the link points at, and the cause that offers
/// keeping alone. Replacing a link is never right — the bytes are not at
/// that position, and writing over it breaks the sharing somebody set up —
/// so the app's replacement refuses it as well.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_shared_by_hand_is_offered_only_the_way_out_that_keeps_it() {
    let f = fixture();
    let folder = f.project.join("elsewhere/deploy");
    fs::create_dir_all(&folder).unwrap();
    fs::write(
        folder.join("SKILL.md"),
        "---\nname: deploy\ndescription: does deploy\n---\nShared by hand.\n",
    )
    .unwrap();
    let position = f.project.join(".claude/skills/deploy");
    fs::remove_dir_all(&position).unwrap();
    std::os::unix::fs::symlink(&folder, &position).unwrap();

    let row = view(&f.env, &f.scope)
        .drift
        .into_iter()
        .find(|row| row.name == "deploy")
        .unwrap();
    assert_eq!(
        row.cause,
        Some(kendex_core::engine::DriftCause::SharedLink),
        "{row:?}"
    );
    assert!(row.cause.unwrap().can_keep());
    assert!(!row.cause.unwrap().can_replace());
    assert!(
        row.detail.contains("elsewhere/deploy"),
        "the row names the folder, not the link: {}",
        row.detail
    );

    let refused = replace_unmanaged(&f.env, &f.scope, ItemKind::Skill, "deploy".into());
    assert!(
        refused.is_err(),
        "a link somebody else made was written over"
    );
    assert!(position.is_symlink(), "the link is left exactly as it was");
}

/// A skill declared for two tools, with hand-made files at both places.
#[allow(clippy::unwrap_used)]
fn two_tools() -> Fixture {
    let f = fixture();
    let path = f.project.join("kendex.toml");
    let both = fs::read_to_string(&path).unwrap().replace(
        "harnesses = [\"claude\"]",
        "harnesses = [\"claude\", \"codex\"]",
    );
    fs::write(&path, both).unwrap();
    for name in ["deploy", "lint"] {
        let here = f.project.join(format!(".agents/skills/{name}"));
        fs::create_dir_all(&here).unwrap();
        fs::write(here.join("SKILL.md"), "the tool that came before").unwrap();
    }
    f
}

/// One exit for one item, however many tools hold it. The row offers
/// replacing only where every place allows it, so a check that asks whether
/// any one of them does approves a choice the page in front of the reader
/// would not draw — and takes over half the item, leaving the rest blocked.
#[test]
#[allow(clippy::unwrap_used)]
fn replacing_stops_when_one_of_an_item_s_places_stops_allowing_it() {
    let f = two_tools();
    // Codex's place turns into a folder somebody else shares by hand, which
    // is never written over.
    let folder = f.project.join("elsewhere/deploy");
    fs::create_dir_all(&folder).unwrap();
    fs::write(
        folder.join("SKILL.md"),
        "---\nname: deploy\ndescription: does deploy\n---\nShared by hand.\n",
    )
    .unwrap();
    let position = f.project.join(".agents/skills/deploy");
    fs::remove_dir_all(&position).unwrap();
    std::os::unix::fs::symlink(&folder, &position).unwrap();

    let causes: Vec<_> = view(&f.env, &f.scope)
        .drift
        .into_iter()
        .filter(|row| row.name == "deploy")
        .filter_map(|row| row.cause)
        .collect();
    assert!(
        causes.iter().any(|c| !c.can_replace()) && causes.iter().any(|c| c.can_replace()),
        "the fixture is not the mixed state it is testing: {causes:?}"
    );

    let refused = replace_unmanaged(&f.env, &f.scope, ItemKind::Skill, "deploy".into());
    assert!(refused.is_err(), "half the item was taken over");
    assert_eq!(
        body(&f, "deploy"),
        "the tool that came before",
        "one tool's copy was written over while the other stayed blocked"
    );
    assert!(position.is_symlink(), "the link is left exactly as it was");
}

/// The check and the plan it guards come from one read. Between a separate
/// look at the disk and the plan, the files can go: the second read sees an
/// ordinary missing install, and the scope's whole apply runs for a button
/// that answered a question already gone.
#[test]
#[allow(clippy::unwrap_used)]
fn a_choice_settled_between_the_look_and_the_plan_changes_nothing() {
    let f = fixture();
    let deploy = f.project.join(".claude/skills/deploy");

    // Exactly what a second read would find: nothing in the way any more.
    fs::remove_dir_all(&deploy).unwrap();

    let refused = replace_unmanaged(&f.env, &f.scope, ItemKind::Skill, "deploy".into());
    assert!(refused.is_err(), "a stale choice was carried out");
    assert!(
        !deploy.join("SKILL.md").exists(),
        "the item was installed by a choice that was about replacing it"
    );
    assert_eq!(
        body(&f, "lint"),
        "the tool that came before",
        "and the rest of the scope was applied on the way past"
    );
}

/// A conflict of another kind beside the files. It carries no exit of its
/// own, and the page has to see it anyway: left out, the row it sits on
/// would offer a replacement the plan then refuses for the whole item.
#[test]
#[allow(clippy::unwrap_used)]
fn a_conflict_with_no_exit_of_its_own_still_reaches_the_page() {
    let f = fixture();
    let installed = view(&f.env, &f.scope);
    assert!(!installed.drift.is_empty());

    // deploy installed from the catalog, then pointed at somewhere else:
    // a clash the exits cannot settle, on an item whose other place holds
    // files kendex did not write.
    fs::remove_dir_all(f.project.join(".claude/skills/deploy")).unwrap();
    let report = kendex_core::engine::plan_apply(
        &f.env,
        &f.scope,
        &kendex_core::engine::PlanOptions::default(),
    )
    .unwrap();
    kendex_core::apply::execute(&f.env, &report.plan).unwrap();
    let elsewhere = f.project.parent().unwrap().join("second");
    fs::create_dir_all(elsewhere.join("skills/deploy")).unwrap();
    fs::write(
        elsewhere.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: does deploy\n---\nSomewhere else.\n",
    )
    .unwrap();
    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    let (head, tail) = text.split_once("[install]").unwrap();
    fs::write(
        &manifest,
        format!(
            "{head}[sources.other]\n{}\n\n[install]{}",
            source_path(&elsewhere),
            tail.replace(
                "[skills.deploy]\nsource = \"cat\"",
                "[skills.deploy]\nsource = \"other\""
            )
        ),
    )
    .unwrap();

    let after = view(&f.env, &f.scope);
    let clash = after
        .drift
        .iter()
        .find(|row| row.name == "deploy" && row.cause.is_none())
        .unwrap_or_else(|| panic!("no clash in {:?}", after.drift));
    assert!(
        after.exits.iter().any(
            |exit| exit.key == format!("skill:deploy:{}", clash.harness.name())
                && exit.blocking
                && !exit.keep
                && !exit.replace
        ),
        "the page cannot see it: {:?}",
        after.exits
    );
}
