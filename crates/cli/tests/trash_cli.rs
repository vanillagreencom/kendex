//! The trash at the command line: `kendex trash list` and `kendex trash
//! empty`, and the pass every writing verb closes on, which brings the
//! trash within its bounds and never takes what that verb itself wrote.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::env::Env;

const DAY: u64 = 86_400;

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, vars: &[(&str, &str)], args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .envs(vars.iter().copied())
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn answered(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn trash_dir(home: &Path) -> PathBuf {
    Env::host_rooted(home).trash_dir()
}

/// An entry an earlier invocation moved into the trash `age` seconds ago
/// under `base`, holding one file of `bytes` bytes.
#[allow(clippy::unwrap_used)]
fn plant(home: &Path, age: u64, base: &str, bytes: usize) -> String {
    let stamp =
        kendex_core::clock::iso_from_unix(kendex_core::clock::unix_now() - age).replace(':', "-");
    let name = format!("{stamp}-{base}");
    let entry = trash_dir(home).join(&name);
    fs::create_dir_all(&entry).unwrap();
    fs::write(entry.join("blob"), vec![b'x'; bytes]).unwrap();
    name
}

#[allow(clippy::unwrap_used)]
fn names(home: &Path) -> Vec<String> {
    let mut names: Vec<String> = match fs::read_dir(trash_dir(home)) {
        Ok(listing) => listing
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect(),
        Err(_) => Vec::new(),
    };
    names.sort();
    names
}

/// A project declaring skill `deploy` from a local catalog, with `deploy`
/// already on disk, laid out by another tool: the shape whose take-over
/// puts a tree in the trash.
#[allow(clippy::unwrap_used)]
fn migrating_project(home: &Path) -> PathBuf {
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/skills/deploy")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            source_path(&catalog)
        ),
    )
    .unwrap();
    fs::write(
        project.join(".claude/skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nWritten by the tool that came before.\n",
    )
    .unwrap();
    project
}

#[allow(clippy::unwrap_used)]
fn fixture() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    (tmp, home)
}

/// One line per entry on stdout, newest first, with its age and size;
/// the count and the total on stderr.
#[test]
fn list_prints_each_entry_with_its_age_and_size_newest_first() {
    let (_tmp, home) = fixture();
    let old = plant(&home, 3 * DAY + 2 * 3600, "old-skill", 1500);
    let young = plant(&home, 5 * 3600, "young-skill", 240 * 1024);

    let listed = kendex(&home, &home, &[], &["trash", "list"]);
    assert!(listed.status.success(), "{}", said(&listed));
    let stdout = answered(&listed);
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines.len(), 2, "{lines:?}");
    assert_eq!(lines[0], format!("{young}  5h 0m  240 KB"));
    assert_eq!(lines[1], format!("{old}  3d 2h  1 KB"));
    assert!(
        said(&listed).contains("2 entries, 241 KB"),
        "{}",
        said(&listed)
    );

    let empty = kendex(&home, &home, &[], &["trash", "empty", "--yes"]);
    assert!(empty.status.success(), "{}", said(&empty));
    let listed = kendex(&home, &home, &[], &["trash", "list"]);
    assert!(listed.status.success(), "{}", said(&listed));
    assert!(answered(&listed).is_empty(), "{}", answered(&listed));
    assert!(
        said(&listed).contains("the trash is empty"),
        "{}",
        said(&listed)
    );
}

/// An age narrows the emptying to the entries past it, and needs no
/// answer: the bound is the answer.
#[test]
fn empty_older_than_removes_only_the_entries_past_that_age() {
    let (_tmp, home) = fixture();
    let young = plant(&home, DAY, "young", 10);
    plant(&home, 10 * DAY, "old", 10);
    plant(&home, 40 * DAY, "older", 10);

    let emptied = kendex(&home, &home, &[], &["trash", "empty", "--older-than", "7"]);
    assert!(emptied.status.success(), "{}", said(&emptied));
    assert!(
        said(&emptied).contains("removed 2 entries"),
        "{}",
        said(&emptied)
    );
    assert_eq!(names(&home), [young]);
}

/// With no bound the verb asks, and with nobody to ask it refuses naming
/// the flag that answers, before it removes anything. The trash is the
/// one way back from a removal nobody wanted, so it never empties on a
/// bare typo.
#[test]
fn empty_without_a_bound_asks_and_refuses_with_nobody_to_ask() {
    let (_tmp, home) = fixture();
    let one = plant(&home, DAY, "one", 10);
    let two = plant(&home, 2 * DAY, "two", 10);

    let refused = kendex(&home, &home, &[], &["trash", "empty"]);
    assert!(!refused.status.success(), "{}", said(&refused));
    assert!(said(&refused).contains("--yes"), "{}", said(&refused));
    assert_eq!(names(&home), [two, one]);

    let emptied = kendex(&home, &home, &[], &["trash", "empty", "--yes"]);
    assert!(emptied.status.success(), "{}", said(&emptied));
    assert!(
        said(&emptied).contains("removed 2 entries"),
        "{}",
        said(&emptied)
    );
    assert!(names(&home).is_empty(), "{:?}", names(&home));
}

/// An ordinary `kendex apply` closes on the pass: the entry past the age
/// bound and the one that takes the total past the size bound go, the
/// younger one stays, and the tree the apply itself moved to the trash
/// stays whatever the bounds say.
#[test]
fn an_apply_brings_the_trash_within_its_bounds_and_keeps_what_it_wrote() {
    let (_tmp, home) = fixture();
    let project = migrating_project(&home);
    let young = plant(&home, DAY, "young", 10);
    plant(&home, 3 * DAY, "large", 2 * 1024 * 1024);
    plant(&home, 40 * DAY, "old", 10);
    let bounds = [
        ("KENDEX_TRASH_KEEP_DAYS", "7"),
        ("KENDEX_TRASH_KEEP_MB", "1"),
    ];

    let applied = kendex(
        &home,
        &project,
        &bounds,
        &["apply", "-y", "--replace-unmanaged"],
    );
    assert!(applied.status.success(), "{}", said(&applied));
    assert!(
        said(&applied).contains("trash: removed 2 older entries"),
        "{}",
        said(&applied)
    );
    let kept = names(&home);
    assert_eq!(kept.len(), 2, "{kept:?}");
    assert!(kept.contains(&young), "{kept:?}");
    assert!(
        kept.iter().any(|name| name.ends_with("-deploy")),
        "the tree this apply moved aside is gone: {kept:?}"
    );
}

/// `refresh` and `remove` close on the same pass, after their own writes.
#[test]
fn refresh_and_remove_close_on_the_pass_too() {
    let rows: [(&str, &[&str]); 2] = [
        ("refresh", &["refresh", "-y", "--scope", "project"]),
        ("remove", &["remove", "deploy"]),
    ];
    for (verb, args) in rows {
        let (_tmp, home) = fixture();
        let project = migrating_project(&home);
        let installed = kendex(
            &home,
            &project,
            &[],
            &["apply", "-y", "--replace-unmanaged"],
        );
        assert!(installed.status.success(), "{verb}: {}", said(&installed));
        let young = plant(&home, DAY, "young", 10);
        plant(&home, 40 * DAY, "old", 10);
        let bounds = [("KENDEX_TRASH_KEEP_DAYS", "7")];

        let closed = kendex(&home, &project, &bounds, args);
        assert!(closed.status.success(), "{verb}: {}", said(&closed));
        assert!(
            said(&closed).contains("trash: removed 1 older entry"),
            "{verb}: {}",
            said(&closed)
        );
        let kept = names(&home);
        assert!(kept.contains(&young), "{verb}: {kept:?}");
        assert!(
            !kept.iter().any(|name| name.ends_with("-old")),
            "{verb}: {kept:?}"
        );
    }
}

/// A bound exported as something other than a count stops the pass with
/// everything intact and says which variable it could not read, and the
/// verb still succeeds; one exported empty reads as the default.
#[test]
fn a_bound_that_is_not_a_count_removes_nothing_and_an_empty_one_is_the_default() {
    let rows: [(&str, &str); 2] = [
        ("KENDEX_TRASH_KEEP_DAYS", "KENDEX_TRASH_KEEP_MB"),
        ("KENDEX_TRASH_KEEP_MB", "KENDEX_TRASH_KEEP_DAYS"),
    ];
    for (garbage, other) in rows {
        let (_tmp, home) = fixture();
        let project = migrating_project(&home);
        let young = plant(&home, DAY, "young", 10);
        let old = plant(&home, 40 * DAY, "old", 10);

        let stopped = kendex(
            &home,
            &project,
            &[(garbage, "lots"), (other, "")],
            &["apply", "-y", "--replace-unmanaged"],
        );
        assert!(stopped.status.success(), "{garbage}: {}", said(&stopped));
        assert!(
            said(&stopped).contains(garbage),
            "{garbage}: {}",
            said(&stopped)
        );
        assert!(
            !said(&stopped).contains("trash: removed"),
            "{garbage}: {}",
            said(&stopped)
        );
        let kept = names(&home);
        assert!(
            kept.contains(&young) && kept.contains(&old),
            "{garbage}: {kept:?}"
        );

        let defaulted = kendex(
            &home,
            &project,
            &[(garbage, ""), (other, "")],
            &["refresh", "-y", "--scope", "project"],
        );
        assert!(
            defaulted.status.success(),
            "{garbage}: {}",
            said(&defaulted)
        );
        assert!(
            said(&defaulted).contains("trash: removed 1 older entry"),
            "{garbage}: {}",
            said(&defaulted)
        );
        let kept = names(&home);
        assert!(
            kept.contains(&young) && !kept.contains(&old),
            "{garbage}: {kept:?}"
        );
    }
}

/// The verb is listed where a person looks for it.
#[test]
fn the_help_lists_the_trash_verb() {
    let (_tmp, home) = fixture();
    let help = kendex(&home, &home, &[], &["--help"]);
    assert!(help.status.success());
    assert!(answered(&help).contains("trash"), "{}", answered(&help));
    let sub = kendex(&home, &home, &[], &["trash", "--help"]);
    let text = answered(&sub);
    assert!(text.contains("list") && text.contains("empty"), "{text}");
}
