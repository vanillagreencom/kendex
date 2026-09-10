//! The `bookmark` verb family end to end against an isolated home:
//! saving a marketplace package and a curated set, finding them again,
//! installing one into a project, forgetting one, and what a run with a
//! name that reaches two saved items does.

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

/// A home holding two marketplace folders that each offer a skill called
/// `gh`, the first of them subscribed personally and also offering a
/// curated set, plus an empty project to install into.
#[allow(clippy::unwrap_used)]
fn world() -> (tempfile::TempDir, std::path::PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);

    let catalog = home.join("catalog");
    skill(&catalog.join("skills"), "gh", "market bytes");
    write(
        &catalog.join("kendex.toml"),
        "[marketplace]\nname = \"cat\"\n\n[bundles.starter]\nskills = [\"gh\"]\n",
    );

    let other = home.join("other");
    skill(&other.join("skills"), "gh", "other bytes");
    write(
        &other.join("kendex.toml"),
        "[marketplace]\nname = \"other\"\n",
    );

    // Subscribed personally, so a saved item resolves without the CLI
    // being told where its marketplace is.
    write(
        &home.join(".config/kendex/kendex.toml"),
        &format!(
            "schema = 6\n[install]\nharnesses = [\"claude\"]\n[sources.cat]\n{}\n[sources.other]\n{}\n",
            source_path(&catalog),
            source_path(&other)
        ),
    );
    // The destination declares which tool it installs for, the way a
    // project a person set up does: an install with nobody to ask keeps
    // the destination's own defaults, and a folder that declares none
    // holds nothing.
    fs::create_dir_all(home.join("fresh/.claude")).unwrap();
    write(
        &home.join("fresh/kendex.toml"),
        "schema = 6\n[install]\nharnesses = [\"claude\"]\n",
    );
    (tmp, home)
}

/// The user tasks in one run of the verb family: nothing saved, save a
/// package and a curated set, find them, look at one, install one into a
/// project, and forget it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_item_is_saved_listed_shown_installed_and_forgotten() {
    let (_tmp, home) = world();
    let catalog = home.join("catalog");
    let fresh = home.join("fresh");

    // Nothing yet, said in words rather than as silence — an unreadable
    // index would leave through the verb instead.
    let empty = kendex(&home, &home, &["bookmark", "list"]);
    assert!(empty.status.success(), "{}", said(&empty));
    assert!(
        said(&empty).contains("nothing saved yet"),
        "{}",
        said(&empty)
    );

    for (name, kind) in [("gh", "skill"), ("starter", "bundle")] {
        let saved = kendex(
            &home,
            &home,
            &[
                "bookmark",
                "add",
                name,
                "--kind",
                kind,
                "--source",
                catalog.to_str().unwrap(),
            ],
        );
        assert!(saved.status.success(), "{}", said(&saved));
    }

    let listed = kendex(&home, &home, &["bookmark", "list"]);
    let text = said(&listed);
    assert!(listed.status.success(), "{text}");
    assert!(text.contains("skill gh"), "{text}");
    assert!(text.contains("bundle starter"), "{text}");
    // Both are offered: the marketplace is subscribed and still has them.
    assert_eq!(text.matches("[offered]").count(), 2, "{text}");

    let shown = kendex(&home, &home, &["bookmark", "show", "starter"]);
    assert!(shown.status.success(), "{}", said(&shown));
    assert!(said(&shown).contains("bundle starter"), "{}", said(&shown));

    // Installing a saved item is the ordinary install: the package lands
    // in the project named, which the run registers.
    let installed = kendex(
        &home,
        &home,
        &[
            "bookmark",
            "install",
            "gh",
            "--kind",
            "skill",
            "--project",
            fresh.to_str().unwrap(),
            "--yes",
        ],
    );
    assert!(installed.status.success(), "{}", said(&installed));
    assert!(
        fresh.join(".claude/skills/gh/SKILL.md").exists(),
        "{}",
        said(&installed)
    );

    // Forgetting one leaves what it installed exactly where it is.
    let forgotten = kendex(
        &home,
        &home,
        &["bookmark", "remove", "gh", "--kind", "skill"],
    );
    assert!(forgotten.status.success(), "{}", said(&forgotten));
    assert!(fresh.join(".claude/skills/gh/SKILL.md").exists());
    let left = said(&kendex(&home, &home, &["bookmark", "list"]));
    assert!(!left.contains("skill gh"), "{left}");
    assert!(left.contains("bundle starter"), "{left}");
}

/// A name two saved items wear needs the selector that tells them apart,
/// and a run with nobody to ask fails before it mutates anything, naming
/// what it needed.
#[test]
#[allow(clippy::unwrap_used)]
fn an_ambiguous_name_refuses_naming_the_selector_it_needs() {
    let (_tmp, home) = world();
    let catalog = home.join("catalog");
    let other = home.join("other");
    let fresh = home.join("fresh");

    for source in [&catalog, &other] {
        let saved = kendex(
            &home,
            &home,
            &[
                "bookmark",
                "add",
                "gh",
                "--kind",
                "skill",
                "--source",
                source.to_str().unwrap(),
            ],
        );
        assert!(saved.status.success(), "{}", said(&saved));
    }

    // Removing by the name alone reaches two, so it removes neither and
    // says which flag settles it.
    let refused = kendex(&home, &home, &["bookmark", "remove", "gh"]);
    let text = said(&refused);
    assert!(!refused.status.success(), "{text}");
    assert!(text.contains("--source"), "{text}");
    assert_eq!(
        said(&kendex(&home, &home, &["bookmark", "list"]))
            .matches("skill gh")
            .count(),
        2,
        "a refused removal took a bookmark with it"
    );

    // The same name and the same two candidates, refused before an install
    // writes anything.
    let install = kendex(
        &home,
        &home,
        &[
            "bookmark",
            "install",
            "gh",
            "--project",
            fresh.to_str().unwrap(),
            "--yes",
        ],
    );
    assert!(!install.status.success(), "{}", said(&install));
    assert!(said(&install).contains("--source"), "{}", said(&install));
    assert!(!fresh.join(".claude/skills/gh/SKILL.md").exists());

    // Named, it reaches exactly one.
    let named = kendex(
        &home,
        &home,
        &[
            "bookmark",
            "remove",
            "gh",
            "--source",
            other.to_str().unwrap(),
        ],
    );
    assert!(named.status.success(), "{}", said(&named));
    assert_eq!(
        said(&kendex(&home, &home, &["bookmark", "list"]))
            .matches("skill gh")
            .count(),
        1,
    );
}

/// A saved item whose marketplace cannot be served keeps its row and says
/// so, and installing it refuses rather than reaching for content nobody
/// has read.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unavailable_item_stays_listed_and_cannot_be_installed() {
    let (_tmp, home) = world();
    let catalog = home.join("catalog");
    let fresh = home.join("fresh");
    let saved = kendex(
        &home,
        &home,
        &[
            "bookmark",
            "add",
            "gh",
            "--kind",
            "skill",
            "--source",
            catalog.to_str().unwrap(),
        ],
    );
    assert!(saved.status.success(), "{}", said(&saved));

    fs::remove_dir_all(&catalog).unwrap();

    let listed = kendex(&home, &home, &["bookmark", "list"]);
    let text = said(&listed);
    assert!(listed.status.success(), "{text}");
    assert!(text.contains("skill gh"), "{text}");
    assert!(text.contains("[unavailable]"), "{text}");

    let refused = kendex(
        &home,
        &home,
        &[
            "bookmark",
            "install",
            "gh",
            "--project",
            fresh.to_str().unwrap(),
            "--yes",
        ],
    );
    let text = said(&refused);
    assert!(!refused.status.success(), "{text}");
    assert!(!fresh.join(".claude/skills/gh/SKILL.md").exists());
    // Refused by the standing rather than by the engine meeting the same
    // folder later: the run never says where it was going, because it
    // never went.
    assert!(!text.contains("installing skill gh"), "{text}");
}

/// Saving needs a kind and a marketplace, and a word the vocabulary does
/// not hold is refused naming the words it does.
#[test]
#[allow(clippy::unwrap_used)]
fn saving_needs_the_kind_and_the_marketplace_it_cannot_guess() {
    let (_tmp, home) = world();
    let catalog = home.join("catalog");

    for args in [
        vec!["bookmark", "add", "gh", "--kind", "skill"],
        vec![
            "bookmark",
            "add",
            "gh",
            "--source",
            catalog.to_str().unwrap(),
        ],
    ] {
        let refused = kendex(&home, &home, &args);
        assert!(!refused.status.success(), "{}", said(&refused));
    }

    let unknown = kendex(
        &home,
        &home,
        &[
            "bookmark",
            "add",
            "gh",
            "--kind",
            "skills",
            "--source",
            catalog.to_str().unwrap(),
        ],
    );
    let text = said(&unknown);
    assert!(!unknown.status.success(), "{text}");
    assert!(text.contains("bundle"), "{text}");
    assert!(
        said(&kendex(&home, &home, &["bookmark", "list"])).contains("nothing saved yet"),
        "a refused save wrote a bookmark"
    );
}

/// One repository spelled two ways is one saved item, and a name nothing
/// saved refuses rather than answering with nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn one_repository_spelled_two_ways_saves_once() {
    let (_tmp, home) = world();

    for source in [
        "vanillagreencom/kendex",
        "https://github.com/VanillaGreenCom/kendex.git",
    ] {
        let saved = kendex(
            &home,
            &home,
            &[
                "bookmark", "add", "gh", "--kind", "skill", "--source", source,
            ],
        );
        assert!(saved.status.success(), "{}", said(&saved));
    }
    let listed = said(&kendex(&home, &home, &["bookmark", "list"]));
    assert_eq!(listed.matches("skill gh").count(), 1, "{listed}");
    // Nothing here subscribes to it, which is a standing rather than a
    // failure: the row is listed, and it says so.
    assert!(listed.contains("[not subscribed]"), "{listed}");

    let missing = kendex(&home, &home, &["bookmark", "show", "nothing"]);
    assert!(!missing.status.success(), "{}", said(&missing));
    assert!(
        said(&missing).contains("nothing saved is called"),
        "{}",
        said(&missing)
    );
}
