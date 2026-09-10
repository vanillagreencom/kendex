//! `kendex template …` end to end against an isolated home: saving a
//! project's packages, listing and showing them, installing into another
//! project, and what a run with nobody to ask does.

#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

// Integration-test helpers sit outside #[test] fns, so clippy's
// allow-unwrap-in-tests does not reach them.
#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

/// The same run with a terminal's answer already given.
fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn skill(dir: &Path, name: &str, body: &str) {
    write(
        &dir.join(name).join("SKILL.md"),
        &format!("---\nname: {name}\ndescription: about {name}\n---\n{body}\n"),
    );
}

/// A home holding a marketplace folder, a project that installs a package
/// from it and keeps one of its own, and an empty project to install into.
#[allow(clippy::unwrap_used)]
fn world() -> (tempfile::TempDir, std::path::PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    skill(&catalog.join("skills"), "gh", "market bytes");
    write(
        &catalog.join("kendex.toml"),
        "[marketplace]\nname = \"cat\"\n",
    );

    let app = home.join("app");
    skill(
        &app.join(kendex_core::source::LOCAL_SOURCE_DIR)
            .join("skills"),
        "house-style",
        "my own bytes",
    );
    skill(&app.join(".claude/skills"), "stray", "unmanaged bytes");
    write(
        &app.join("kendex.toml"),
        &format!(
            "schema = 6\n[install]\nharnesses = [\"claude\"]\n[sources.cat]\n{}\n[skills.gh]\nsource = \"cat\"\n[skills.house-style]\nsource = \"local\"\n",
            source_path(&catalog)
        ),
    );
    fs::create_dir_all(home.join("fresh/.claude")).unwrap();
    // The project is a real one: what it declares is installed, which is
    // what gives a template bytes to copy.
    let applied = kendex(&home, &app, &["apply", "--yes"]);
    assert!(applied.status.success(), "{}", said(&applied));
    (tmp, home)
}

/// The user tasks in one run of the verb family: save a project, list it,
/// show what it installs, install it somewhere else, and delete it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_template_is_saved_from_a_project_listed_shown_installed_and_deleted() {
    let (_tmp, home) = world();
    let app = home.join("app");
    let fresh = home.join("fresh");

    // Nothing yet, said in words rather than as silence.
    let empty = kendex(&home, &home, &["template", "list"]);
    assert!(empty.status.success(), "{}", said(&empty));
    assert!(
        said(&empty).contains("no templates yet"),
        "{}",
        said(&empty)
    );

    let created = kendex(
        &home,
        &home,
        &[
            "template",
            "create",
            "Rust service",
            "--from-project",
            app.to_str().unwrap(),
            "--include-local",
            "--yes",
        ],
    );
    assert!(created.status.success(), "{}", said(&created));
    let text = said(&created);
    // The sentence the issue fixes, said before anything is copied.
    assert!(
        text.contains("Copies go into this template. Files in this project stay unchanged."),
        "{text}"
    );

    let listed = kendex(&home, &home, &["template", "list"]);
    assert!(said(&listed).contains("Rust service"), "{}", said(&listed));

    let shown = kendex(&home, &home, &["template", "show", "Rust service"]);
    let text = said(&shown);
    assert!(shown.status.success(), "{text}");
    for wanted in ["gh", "house-style", "stray"] {
        assert!(text.contains(wanted), "{text}");
    }

    // The project it was read from is untouched: its own manifest still
    // declares what it declared, and nothing was adopted.
    let manifest = fs::read_to_string(app.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[skills.house-style]"), "{manifest}");
    assert!(!manifest.contains("[skills.stray]"), "{manifest}");

    let installed = kendex(
        &home,
        &home,
        &[
            "template",
            "install",
            "Rust service",
            "--project",
            fresh.to_str().unwrap(),
            "--yes",
        ],
    );
    let text = said(&installed);
    assert!(installed.status.success(), "{text}");
    let landed = fs::read_to_string(fresh.join("kendex.toml")).unwrap();
    for wanted in ["[skills.gh]", "[skills.house-style]", "[skills.stray]"] {
        assert!(landed.contains(wanted), "{landed}");
    }
    // The copies are the destination's own bytes.
    let copied = fresh
        .join(kendex_core::source::LOCAL_SOURCE_DIR)
        .join("skills/stray/SKILL.md");
    assert!(
        fs::read_to_string(&copied)
            .unwrap()
            .contains("unmanaged bytes")
    );

    let deleted = kendex(
        &home,
        &home,
        &["template", "delete", "Rust service", "--yes"],
    );
    assert!(deleted.status.success(), "{}", said(&deleted));
    // Deleting reaches nothing that was installed from it.
    assert!(copied.is_file());
    assert!(said(&kendex(&home, &home, &["template", "list"])).contains("no templates yet"));
}

/// Without a terminal and without `--yes`, a run that would write refuses
/// before its first write and names the flag that would have answered it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_write_with_nobody_to_ask_refuses_before_it_writes() {
    let (_tmp, home) = world();
    let app = home.join("app");
    let refused = kendex(
        &home,
        &home,
        &[
            "template",
            "create",
            "Rust service",
            "--from-project",
            app.to_str().unwrap(),
        ],
    );
    let text = said(&refused);
    assert!(!refused.status.success(), "{text}");
    assert!(text.contains("--yes"), "{text}");
    // Nothing was saved, and the project is as it was.
    assert!(
        said(&kendex(&home, &home, &["template", "list"])).contains("no templates yet"),
        "{text}"
    );
    assert!(!app.join(".kendex-local/skills/stray").exists());
}

/// A name is required and never reused; a template nobody saved is a
/// refusal rather than an empty answer.
#[test]
#[allow(clippy::unwrap_used)]
fn names_are_checked_and_an_unknown_template_refuses() {
    let (_tmp, home) = world();
    let app = home.join("app");
    let create = |name: &str| {
        kendex(
            &home,
            &home,
            &[
                "template",
                "create",
                name,
                "--from-project",
                app.to_str().unwrap(),
                "--yes",
            ],
        )
    };
    assert!(create("Rust service").status.success());
    let again = create("Rust service");
    assert!(!again.status.success(), "{}", said(&again));
    assert!(said(&again).contains("already called"), "{}", said(&again));

    let missing = kendex(&home, &home, &["template", "show", "Nothing"]);
    assert!(!missing.status.success(), "{}", said(&missing));
    assert!(
        said(&missing).contains("no template called"),
        "{}",
        said(&missing)
    );
}

/// `project add --template` is one path: the folder is registered and the
/// template lands in it.
#[test]
#[allow(clippy::unwrap_used)]
fn registering_a_project_can_install_a_template_into_it() {
    let (_tmp, home) = world();
    let app = home.join("app");
    let fresh = home.join("fresh");
    assert!(
        kendex(
            &home,
            &home,
            &[
                "template",
                "create",
                "Rust service",
                "--from-project",
                app.to_str().unwrap(),
                "--include-local",
                "--yes",
            ],
        )
        .status
        .success()
    );
    let added = kendex(
        &home,
        &home,
        &[
            "project",
            "add",
            fresh.to_str().unwrap(),
            "--template",
            "Rust service",
            "--yes",
        ],
    );
    let text = said(&added);
    assert!(added.status.success(), "{text}");
    let landed = fs::read_to_string(fresh.join("kendex.toml")).unwrap();
    assert!(landed.contains("[skills.gh]"), "{landed}");
}

/// Members are added and taken out by ordinary selectors, and a run that
/// names no package says which flags name one.
#[test]
#[allow(clippy::unwrap_used)]
fn members_are_named_with_the_selectors_every_other_verb_takes() {
    let (_tmp, home) = world();
    let catalog = home.join("catalog");
    let created = kendex(
        &home,
        &home,
        &[
            "template",
            "create",
            "Picked",
            "--source",
            catalog.to_str().unwrap(),
            "--skill",
            "gh",
        ],
    );
    assert!(created.status.success(), "{}", said(&created));

    let bare = kendex(&home, &home, &["template", "add", "Picked"]);
    assert!(!bare.status.success(), "{}", said(&bare));
    assert!(said(&bare).contains("--skill"), "{}", said(&bare));

    let removed = kendex(
        &home,
        &home,
        &["template", "remove", "Picked", "--skill", "gh"],
    );
    assert!(removed.status.success(), "{}", said(&removed));
    assert!(
        said(&removed).contains("0 package(s)"),
        "{}",
        said(&removed)
    );
}
