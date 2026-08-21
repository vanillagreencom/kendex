//! The app's answer to "files are already there": each row's two buttons
//! act on that row alone. Taking one over must never take a neighbour's
//! files with it — the page shows several blocked items at once, and a
//! click lands on the one a person is reading.
#![cfg(unix)]

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
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
            source.display()
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
/// can take — never by keeping its own copy of the list. A hook or a
/// command offered that button reached a command that refuses, on a screen
/// whose whole job is helping the reader pick between two ways out.
#[test]
#[allow(clippy::unwrap_used)]
fn the_page_is_told_which_kinds_can_be_kept() {
    let f = fixture();
    assert_eq!(
        view(&f.env, &f.scope).adoptable,
        vec![ItemKind::Agent, ItemKind::Skill],
    );
    let refused = kendex_core::engine::adopt::adopt(
        &f.env,
        &f.scope,
        ItemKind::Command,
        "ship",
        kendex_core::model::HarnessId::Claude,
    );
    assert!(
        refused.is_err(),
        "the list and what adoption actually takes have drifted apart"
    );
}
