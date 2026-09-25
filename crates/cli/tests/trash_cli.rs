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

/// Whether `first` is printed before `second`, both present.
fn before(text: &str, first: &str, second: &str) -> bool {
    match (text.find(first), text.find(second)) {
        (Some(a), Some(b)) => a < b,
        _ => false,
    }
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

/// With no bound, or an age of zero, which narrows nothing, the verb
/// asks, and with nobody to ask it refuses naming the flag that answers,
/// before it removes anything. The trash is the one way back from a
/// removal nobody wanted, so it never empties on a bare typo.
#[test]
fn empty_without_a_bound_asks_and_refuses_with_nobody_to_ask() {
    let (_tmp, home) = fixture();
    let one = plant(&home, DAY, "one", 10);
    let two = plant(&home, 2 * DAY, "two", 10);

    let rows: [&[&str]; 2] = [
        &["trash", "empty"],
        &["trash", "empty", "--older-than", "0"],
    ];
    for args in rows {
        let refused = kendex(&home, &home, &[], args);
        assert!(!refused.status.success(), "{args:?}: {}", said(&refused));
        assert!(
            said(&refused).contains("--yes"),
            "{args:?}: {}",
            said(&refused)
        );
        assert_eq!(names(&home), [two.clone(), one.clone()], "{args:?}");
    }

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
    // Said before the line the run closes on, so the closing line stays
    // the last thing the run says.
    assert!(
        before(
            &said(&applied),
            "trash: removed 2 older entries",
            &format!("{}: applied", project.display())
        ),
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

/// `refresh` and `remove` close on the same pass, after their own writes
/// and before their closing line.
#[test]
fn refresh_and_remove_close_on_the_pass_too() {
    let rows: [(&str, &[&str], &str); 2] = [
        (
            "refresh",
            &["refresh", "-y", "--scope", "project"],
            "up to date",
        ),
        ("remove", &["remove", "deploy"], "removed 3 changes"),
    ];
    for (verb, args, closing) in rows {
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
            before(
                &said(&closed),
                "trash: removed 1 older entry",
                &format!("{}: {closing}", project.display())
            ),
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

/// A plan writes nothing, so it closes on no pass: the aged entry stays
/// and the run says nothing about the trash.
#[test]
fn a_plan_only_apply_leaves_the_trash_alone() {
    let (_tmp, home) = fixture();
    let project = migrating_project(&home);
    let old = plant(&home, 40 * DAY, "old", 10);

    let planned = kendex(
        &home,
        &project,
        &[("KENDEX_TRASH_KEEP_DAYS", "7")],
        &["apply", "--plan"],
    );
    assert!(planned.status.success(), "{}", said(&planned));
    assert!(!said(&planned).contains("trash:"), "{}", said(&planned));
    assert_eq!(names(&home), [old]);
}

/// An emptying that stops is a failure of the verb: it exits nonzero
/// naming what went and why, and the newest entries are still there.
#[test]
#[allow(clippy::unwrap_used)]
fn an_empty_that_stops_exits_nonzero_naming_what_went() {
    use std::os::unix::fs::PermissionsExt as _;
    if test_util::no_record_on_this_runner() {
        return;
    }
    let (_tmp, home) = fixture();
    let newest = plant(&home, DAY, "newest", 10);
    let stuck = plant(&home, 2 * DAY, "stuck", 10);
    plant(&home, 3 * DAY, "oldest", 10);
    let stuck_dir = trash_dir(&home).join(&stuck);
    fs::set_permissions(&stuck_dir, fs::Permissions::from_mode(0o555)).unwrap();

    let stopped = kendex(&home, &home, &[], &["trash", "empty", "--yes"]);
    fs::set_permissions(&stuck_dir, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(!stopped.status.success(), "{}", said(&stopped));
    let text = said(&stopped);
    assert!(
        text.contains("trash: removed 1 entry, then stopped:") && text.contains("stuck"),
        "{text}"
    );
    assert_eq!(names(&home), [stuck, newest]);
}

/// A scope that fails after an earlier one wrote stops the run, never
/// the finishing of what was written: the earlier scope still closes on
/// its ledger and the trash pass still runs, and the error leaves after.
#[test]
#[allow(clippy::unwrap_used)]
fn a_remove_that_fails_at_a_later_scope_still_closes_the_scopes_it_wrote() {
    let (_tmp, home) = fixture();
    let project = migrating_project(&home);
    let installed = kendex(
        &home,
        &project,
        &[],
        &["apply", "-y", "--replace-unmanaged"],
    );
    assert!(installed.status.success(), "{}", said(&installed));
    plant(&home, 40 * DAY, "old", 10);
    // The global scope, planned second, has a manifest nothing can read.
    let global = Env::host_rooted(&home).global_manifest_file();
    fs::create_dir_all(global.parent().unwrap()).unwrap();
    fs::write(&global, "schema = \n").unwrap();

    let removed = kendex(
        &home,
        &project,
        &[("KENDEX_TRASH_KEEP_DAYS", "7")],
        &["remove", "deploy", "--scope", "all"],
    );
    assert!(!removed.status.success(), "{}", said(&removed));
    let text = said(&removed);
    assert!(text.contains("removed 3 changes"), "{text}");
    assert!(text.contains("trash: removed 1 older entry"), "{text}");
    assert!(!text.contains("Nothing removed"), "{text}");
    assert!(
        !project.join(".claude/skills/deploy").exists(),
        "the project scope's removal was written"
    );
}

/// A remove whose first planned scope fails wrote nothing, and says so
/// with the error alone: no "Nothing removed" above it, since the run
/// stopped rather than found nothing to take.
#[test]
#[allow(clippy::unwrap_used)]
fn a_remove_that_fails_at_its_first_scope_says_only_the_error() {
    let (_tmp, home) = fixture();
    let project = migrating_project(&home);
    fs::write(project.join("kendex.toml"), "schema = \n").unwrap();

    let stopped = kendex(&home, &project, &[], &["remove", "deploy"]);
    assert!(!stopped.status.success(), "{}", said(&stopped));
    let text = said(&stopped);
    assert!(text.contains("kendex.toml"), "{text}");
    assert!(!text.contains("Nothing removed"), "{text}");
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
