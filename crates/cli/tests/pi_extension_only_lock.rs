//! The install record a scope keeps when the plan derives no entry for what
//! it declares, and what `verify` says about the gap.
//!
//! Apply derives no Pi-extension entry, so a scope declaring only those
//! starts with none. The record still has to land: without it the verb
//! reports the scope up to date, nothing marks the project root for the
//! walk-up that prefers it, and nothing on disk states which build wrote the
//! record. The version floor's remedy for an older lock is to move the file
//! aside, which leaves exactly this shape.

#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use crate::test_util;
use test_util::rooted;

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

/// Everything one run said, both streams, in the order a person reading a
/// terminal sees them.
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

const MANIFEST: &str = "schema = 8\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n";
const PACKAGE: &str = "{\n  \"name\": \"pi-widgets\",\n  \"version\": \"1.0.0\",\n  \"pi\": { \"extensions\": [\"index.js\"] }\n}\n";
const INDEX: &str = "export const version = 1;\n";

/// The catalog a Pi declaration reads, laid out under `root`.
fn catalog(root: &Path) {
    write(
        &root.join("catalog/pi-extensions/pi-widgets/package.json"),
        PACKAGE,
    );
    write(
        &root.join("catalog/pi-extensions/pi-widgets/index.js"),
        INDEX,
    );
}

/// A project whose manifest declares one Pi extension and nothing else, with
/// the package already installed and no lock file anywhere. Handed back with
/// the home the run reads, so a case never spells the root a second time.
#[allow(clippy::unwrap_used)]
fn fixture() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    write(&project.join("kendex.toml"), MANIFEST);
    catalog(&project);
    write(
        &project.join(".pi/packages/pi-widgets/package.json"),
        PACKAGE,
    );
    write(&project.join(".pi/packages/pi-widgets/index.js"), INDEX);
    write(
        &project.join(".pi/settings.json"),
        "{\"packages\": [\"./packages/pi-widgets\"]}\n",
    );
    assert!(!project.join(".kendex-lock.json").exists());
    (tmp, home)
}

/// A record at `lock`, carrying the version this build writes — read from
/// the crate rather than typed here, because a floor bump is what strands a
/// scope in the first place and a number copied into a test would go on
/// asserting a stale one.
#[allow(clippy::unwrap_used)]
fn assert_record_landed(lock: &Path) {
    assert!(lock.is_file(), "no install record at {}", lock.display());
    let text = fs::read_to_string(lock).unwrap();
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        value.get("version").and_then(serde_json::Value::as_u64),
        Some(u64::from(kendex_core::lock::LOCK_VERSION)),
        "{text}"
    );
}

/// Both halves of the write, both spellings of the scope, and the state a
/// person is left in.
///
/// The first run has to plan the record. The second has to plan nothing: the
/// restraint in `plan_lock_write` is the only thing between a scope
/// declaring a Pi extension and an "Update the install record" on every run
/// it ever gets, and a case that only ever drives a virgin fixture cannot
/// tell the two apart. `update-pi` then records matching package bytes and
/// `verify` checks the resulting entry.
///
/// The global scope is a second path through the write, its record sitting
/// under the app's own directory and naming no root, so it is driven here
/// rather than left to the project spelling.
#[test]
#[allow(clippy::unwrap_used)]
fn apply_writes_the_record_once_for_a_pi_extension_only_scope() {
    let (_tmp, home) = fixture();
    let project = home.join("dev/app");

    let first = said(&kendex(&home, &project, &["apply", "--yes"]));
    assert!(first.contains("Update the install record"), "{first}");
    assert!(!first.contains("up to date"), "{first}");
    assert_record_landed(&project.join(".kendex-lock.json"));

    // Nothing left to write but the package itself, which only update-pi
    // installs: the closing line names that action as its finish.
    let second = said(&kendex(&home, &project, &["apply", "--yes"]));
    assert!(
        second
            .lines()
            .any(|line| line.trim() == "finish-with=update-pi scope=project"),
        "{second}"
    );
    assert!(!second.contains("Update the install record"), "{second}");

    let recorded = kendex(&home, &project, &["update-pi", "--scope", "project"]);
    assert!(recorded.status.success(), "{recorded:?}");
    let reapplied = kendex(&home, &project, &["apply", "--yes"]);
    assert!(reapplied.status.success(), "{reapplied:?}");
    let checked = kendex(&home, &project, &["verify", "--scope", "project"]);
    assert!(checked.status.success(), "{checked:?}");
    assert_eq!(
        said(&checked).lines().collect::<Vec<_>>(),
        vec![
            "✓ pi-extension pi-widgets [pi]",
            "1 checked, 1 OK, 0 failed",
        ]
    );

    let env = kendex_core::env::Env::host_rooted(&home);
    let manifest = env.global_manifest_file();
    write(&manifest, MANIFEST);
    catalog(manifest.parent().unwrap());
    assert!(!env.global_lock_file().exists());

    let global = kendex(&home, &home, &["apply", "-g", "--yes"]);
    assert!(global.status.success(), "{global:?}");
    assert_record_landed(&env.global_lock_file());
}

/// Every value a run printed under `key=`: the keyed lines a program reads.
fn keyed(output: &str, key: &str) -> Vec<String> {
    let key = format!("{key}=");
    output
        .lines()
        .filter_map(|line| line.split_once(key.as_str()).map(|(_, rest)| rest))
        .map(|rest| rest.trim().to_owned())
        .collect()
}

/// What `check --json --scope project` says of the Pi packages, read from
/// the typed remedy a program acts on: the packages a line names
/// `update-pi` for, the packages a line names with no fix at all, once per
/// line, and the exit code a program reads (1 drift, 2 could not check).
struct Checked {
    update_pi: Vec<String>,
    no_fix: Vec<String>,
    exit: Option<i32>,
}

/// Every line `check --json --scope project` drew, in report order, and
/// its exit code.
#[allow(clippy::unwrap_used)]
fn check_lines(home: &Path, project: &Path) -> (Vec<serde_json::Value>, Option<i32>) {
    let json = kendex(home, project, &["check", "--json", "--scope", "project"]);
    let report: serde_json::Value = serde_json::from_slice(&json.stdout)
        .unwrap_or_else(|error| panic!("check --json is JSON: {error}: {}", said(&json)));
    let lines = report["sections"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|section| section["lines"].as_array().unwrap().iter().cloned())
        .collect();
    (lines, json.status.code())
}

#[allow(clippy::unwrap_used)]
fn checked(home: &Path, project: &Path) -> Checked {
    let (lines, exit) = check_lines(home, project);
    let named = |keep: &dyn Fn(&serde_json::Value) -> bool| {
        let mut named: Vec<String> = lines
            .iter()
            .filter(|line| keep(line))
            .filter_map(|line| {
                let (_, rest) = line["text"]
                    .as_str()
                    .unwrap()
                    .split_once("pi-extension '")?;
                Some(rest.split('\'').next().unwrap().to_owned())
            })
            .collect();
        named.sort();
        named
    };
    Checked {
        update_pi: named(&|line| line["remedy"]["verb"] == "update-pi"),
        no_fix: named(&|line| line.get("remedy").is_none()),
        exit,
    }
}

/// The scope as it stands.
fn project_scope(project: &Path) -> kendex_core::model::Scope {
    kendex_core::model::Scope::Project {
        root: project.to_path_buf(),
    }
}

/// What apply's plan leaves of the declared Pi packages on the scope as it
/// stands, from the typed rows the run's own lists are read off
/// (`commands::offers`): the packages it leaves for `update-pi`, and those
/// neither its write nor `update-pi` settles, one per row. A plan that
/// will not read leaves neither.
fn applied(home: &Path, project: &Path) -> (Vec<String>, Vec<String>) {
    let env = kendex_core::env::Env::host_rooted(home);
    let Ok(report) = kendex_core::engine::plan_apply(
        &env,
        &project_scope(project),
        &kendex_core::engine::PlanOptions::current(),
    ) else {
        return (Vec::new(), Vec::new());
    };
    let named = |keep: &dyn Fn(&kendex_core::engine::DriftRow) -> bool| {
        let mut named: Vec<String> = report
            .drift
            .iter()
            .filter(|row| row.kind == kendex_core::model::ItemKind::PiExtension && keep(row))
            .map(|row| row.name.clone())
            .collect();
        named.sort();
        named
    };
    (
        named(&|row| row.remedy == Some(kendex_core::engine::RowRemedy::UpdatePi)),
        named(&|row| row.pi_unsettled.is_some()),
    )
}

/// The scope's snapshot as the last deep pass stored it.
#[allow(clippy::unwrap_used)]
fn snapshot(home: &Path, project: &Path) -> kendex_core::drift::snapshot::ScopeSnapshot {
    let env = kendex_core::env::Env::host_rooted(home);
    match kendex_core::drift::snapshot::load(&env, &project_scope(project)) {
        kendex_core::drift::snapshot::SnapshotFile::Current(snapshot) => snapshot,
        kendex_core::drift::snapshot::SnapshotFile::Absent
        | kendex_core::drift::snapshot::SnapshotFile::Unreadable(_) => {
            panic!("the run stored no readable snapshot")
        }
    }
}

/// Store `planted` as the scope's snapshot, and read it back, so a case
/// never checks against a snapshot it only meant to write.
#[allow(clippy::unwrap_used)]
fn plant_snapshot(
    home: &Path,
    project: &Path,
    planted: &kendex_core::drift::snapshot::ScopeSnapshot,
) {
    let env = kendex_core::env::Env::host_rooted(home);
    kendex_core::drift::snapshot::store(&env, &project_scope(project), planted).unwrap();
    assert_eq!(
        &snapshot(home, project),
        planted,
        "the planted snapshot reads back"
    );
}

/// A Pi row of the snapshot, every flag cleared.
fn pi_row(name: &str) -> kendex_core::drift::snapshot::PackageSnapshot {
    kendex_core::drift::snapshot::PackageSnapshot {
        kind: kendex_core::model::ItemKind::PiExtension,
        name: name.to_owned(),
        source: "cat".to_owned(),
        repo: String::new(),
        refs_state: None,
        update_available: false,
        removed_upstream: false,
        held: false,
        ignored: false,
        edited: false,
        mixed: false,
        forked: false,
    }
}

/// A Pi note of the snapshot, as a compare that failed writes it.
fn pi_note(name: &str) -> kendex_core::drift::snapshot::UnreadableSnapshot {
    kendex_core::drift::snapshot::UnreadableSnapshot {
        kind: kendex_core::model::ItemKind::PiExtension,
        name: name.to_owned(),
        message: "kendex could not compare the installed Pi package with its source".to_owned(),
        detail: Some("declared package directory is missing".to_owned()),
        repo: String::new(),
        refs_state: None,
    }
}

/// The Pi packages the scope's update standing offers as an update, and
/// those it carries a warning for, from the report the snapshot and the
/// `updates` listing are built from.
#[allow(clippy::unwrap_used)]
fn standing(home: &Path, project: &Path) -> (Vec<String>, Vec<String>) {
    let env = kendex_core::env::Env::host_rooted(home);
    // A manifest that will not read has no standing to offer or warn.
    let Ok(report) = kendex_core::package::updates::updates(&env, &project_scope(project)) else {
        return (Vec::new(), Vec::new());
    };
    let pi = kendex_core::model::ItemKind::PiExtension;
    let mut offered: Vec<String> = report
        .rows
        .iter()
        .filter(|row| row.kind == pi && row.update_available)
        .map(|row| row.name.clone())
        .collect();
    let mut warned: Vec<String> = report
        .warnings
        .iter()
        .filter(|warning| warning.kind == pi)
        .map(|warning| warning.name.clone())
        .collect();
    for names in [&mut offered, &mut warned] {
        names.sort();
        names.dedup();
    }
    (offered, warned)
}

/// The personal Pi root holding its own copy of `pi-widgets`.
#[allow(clippy::unwrap_used)]
fn loaded_from_the_personal_scope(home: &Path) {
    let env = kendex_core::env::Env::host_rooted(home);
    let personal =
        kendex_core::pi_ext::scope_root(&env, &kendex_core::model::Scope::Global).unwrap();
    write(&personal.join("packages/pi-widgets/package.json"), PACKAGE);
    write(&personal.join("packages/pi-widgets/index.js"), INDEX);
}

/// The closing line names `update-pi` as the finish only where running it
/// finishes the scope, and a declared package neither the run's write nor
/// `update-pi` settles is named and counted, so the run never closes as up
/// to date over it. On the scope as it stands, `check` names `update-pi`
/// for exactly the packages apply's plan leaves for it and gives exactly
/// the packages the plan leaves unsettled their reason with no fix, one
/// line each, and exits clean only where the plan leaves no Pi package; a
/// mute does not silence that line. `verify` does not offer `update-pi` as
/// the record's remedy for a package it leaves. Beside a package whose
/// source no longer ships it, update-pi notes that one as not evaluated and fails; for a copy Pi
/// already loads from the personal scope, it leaves the copy blocked, so
/// neither finish is named beside it, the take-over included, which
/// installs no Pi package. A native filter the run itself writes holds
/// nothing back: the package left beside it names update-pi as the finish.
#[test]
#[allow(clippy::unwrap_used)]
fn the_finish_is_update_pi_only_where_update_pi_finishes_the_scope() {
    type Plant = fn(&Path, &Path);
    struct Row {
        case: &'static str,
        /// Everything before the run the row asserts on.
        plant: Plant,
        finish: &'static [&'static str],
        settle_with: &'static [&'static str],
        /// What changes after the run and before `check`, which no run
        /// of kendex's sees.
        after: Option<Plant>,
        /// The package the run names though nothing settles it.
        unsettled: Option<&'static str>,
        /// The packages `check` names `update-pi` for afterwards, and the
        /// update standing offers as an update.
        check_update_pi: &'static [&'static str],
        /// The packages `check` names with their reason and no fix, which
        /// the update standing carries a warning for.
        check_left: &'static [&'static str],
        /// `check`'s exit code: 2 where a package was not evaluated.
        check_exit: i32,
    }
    fn settled_once(home: &Path, project: &Path) {
        kendex(home, project, &["apply", "--yes"]);
    }
    let gone: Plant = |home, project| {
        write(
            &project.join("kendex.toml"),
            &format!("{MANIFEST}\n[pi-extensions.pi-gone]\nsource = \"cat\"\n"),
        );
        kendex(home, project, &["apply", "--yes"]);
    };
    let loaded_twice: Plant = |home, project| {
        loaded_from_the_personal_scope(home);
        kendex(home, project, &["apply", "--yes"]);
    };
    let toggled_beside_a_left_package: Plant = |home, project| {
        settled_once(home, project);
        let installed = kendex(home, project, &["update-pi", "--scope", "project"]);
        assert!(installed.status.success(), "{}", said(&installed));
        settled_once(home, project);
        let other = project.join("catalog/pi-extensions/pi-other");
        write(
            &other.join("package.json"),
            &PACKAGE.replace("pi-widgets", "pi-other"),
        );
        write(&other.join("index.js"), INDEX);
        write(
            &project.join("kendex.toml"),
            &format!("{MANIFEST}enabled = false\n\n[pi-extensions.pi-other]\nsource = \"cat\"\n"),
        );
    };
    let loaded_twice_beside_a_replaceable_conflict: Plant = |home, project| {
        loaded_from_the_personal_scope(home);
        write(
            &project.join("catalog/skills/deploy/SKILL.md"),
            "---\nname: deploy\ndescription: ship the service\n---\nRun the deploy.\n",
        );
        write(
            &project.join(".agents/skills/deploy/SKILL.md"),
            "my own deploy notes\n",
        );
        write(
            &project.join("kendex.toml"),
            &format!(
                "{MANIFEST}\n[skills.deploy]\nsource = \"cat\"\n\n[install]\nharnesses = [\"claude\"]\n"
            ),
        );
        kendex(home, project, &["apply", "--yes"]);
    };
    let recorded_from_another_source: Plant = |home, project| {
        settled_once(home, project);
        let installed = kendex(home, project, &["update-pi", "--scope", "project"]);
        assert!(installed.status.success(), "{}", said(&installed));
        settled_once(home, project);
        let two = project.join("catalog2/pi-extensions/pi-widgets");
        write(&two.join("package.json"), PACKAGE);
        write(&two.join("index.js"), INDEX);
        write(
            &project.join("kendex.toml"),
            &format!(
                "{}\n[sources.two]\npath = \"catalog2\"\n",
                MANIFEST.replace("source = \"cat\"", "source = \"two\"")
            ),
        );
    };
    fn installed_and_recorded(home: &Path, project: &Path) {
        settled_once(home, project);
        let installed = kendex(home, project, &["update-pi", "--scope", "project"]);
        assert!(installed.status.success(), "{}", said(&installed));
        settled_once(home, project);
    }
    fn moved_on(home: &Path, project: &Path) {
        installed_and_recorded(home, project);
        write(
            &project.join("catalog/pi-extensions/pi-widgets/index.js"),
            "export const version = 2;\n",
        );
    }
    let moved_on_and_loaded_twice: Plant = |home, project| {
        moved_on(home, project);
        loaded_from_the_personal_scope(home);
    };
    let moved_on_and_muted: Plant = |home, project| {
        moved_on(home, project);
        kendex_core::package::updates::set_ignored(
            &kendex_core::env::Env::host_rooted(home),
            &project_scope(project),
            kendex_core::model::ItemKind::PiExtension,
            "pi-widgets",
            "",
            true,
        )
        .unwrap();
    };
    let the_mute_reached_the_snapshot: Plant = |home, project| {
        assert!(
            snapshot(home, project)
                .packages
                .iter()
                .any(|row| row.name == "pi-widgets" && row.ignored),
            "the run's snapshot carries the mute"
        );
    };
    // Every Pi row class the snapshot can hold, for a package declared
    // in a manifest that no longer reads and for one never declared.
    let manifest_unreadable: Plant = |home, project| {
        let mut planted = snapshot(home, project);
        for name in ["pi-widgets", "pi-stray"] {
            planted
                .packages
                .push(kendex_core::drift::snapshot::PackageSnapshot {
                    update_available: true,
                    ..pi_row(name)
                });
            planted
                .packages
                .push(kendex_core::drift::snapshot::PackageSnapshot {
                    removed_upstream: true,
                    ..pi_row(name)
                });
            planted.unreadable.push(pi_note(name));
        }
        plant_snapshot(home, project, &planted);
        write(&project.join("kendex.toml"), "schema = [\n");
    };
    let loaded_from_the_personal_scope_now: Plant = |home, _| loaded_from_the_personal_scope(home);
    let personal_copy_removed: Plant = |home, project| {
        let env = kendex_core::env::Env::host_rooted(home);
        let scope = kendex_core::model::Scope::Project {
            root: project.to_path_buf(),
        };
        let kendex_core::drift::snapshot::SnapshotFile::Current(snapshot) =
            kendex_core::drift::snapshot::load(&env, &scope)
        else {
            panic!("the run wrote no snapshot");
        };
        assert!(
            snapshot
                .unreadable
                .iter()
                .any(|note| note.name == "pi-widgets"),
            "the run's snapshot carries the loaded-twice warning"
        );
        let personal =
            kendex_core::pi_ext::scope_root(&env, &kendex_core::model::Scope::Global).unwrap();
        fs::remove_dir_all(personal.join("packages/pi-widgets")).unwrap();
    };
    const UPDATE_PI: &str = "update-pi scope=project";
    let rows = [
        Row {
            case: "a declared package its source no longer ships",
            plant: gone,
            finish: &[],
            settle_with: &[UPDATE_PI],
            after: None,
            unsettled: Some("pi-gone"),
            check_update_pi: &["pi-widgets"],
            check_left: &["pi-gone"],
            check_exit: 2,
        },
        Row {
            case: "a copy Pi already loads from the personal scope",
            plant: loaded_twice,
            finish: &[],
            settle_with: &[],
            after: None,
            unsettled: Some("pi-widgets"),
            check_update_pi: &[],
            check_left: &["pi-widgets"],
            check_exit: 1,
        },
        Row {
            case: "a filter the run writes beside a package left for update-pi",
            plant: toggled_beside_a_left_package,
            finish: &[UPDATE_PI],
            settle_with: &[UPDATE_PI],
            after: None,
            unsettled: None,
            check_update_pi: &["pi-other"],
            check_left: &[],
            check_exit: 1,
        },
        Row {
            case: "a copy Pi loads twice beside a conflict the take-over replaces",
            plant: loaded_twice_beside_a_replaceable_conflict,
            finish: &[],
            settle_with: &[],
            after: None,
            unsettled: Some("pi-widgets"),
            check_update_pi: &[],
            check_left: &["pi-widgets"],
            check_exit: 1,
        },
        Row {
            case: "a record naming another source than the declaration",
            plant: recorded_from_another_source,
            finish: &[],
            settle_with: &[],
            after: None,
            unsettled: Some("pi-widgets"),
            check_update_pi: &[],
            check_left: &["pi-widgets"],
            check_exit: 1,
        },
        Row {
            case: "a recorded copy whose source moved on, loaded from the personal scope too",
            plant: moved_on_and_loaded_twice,
            finish: &[],
            settle_with: &[],
            after: None,
            unsettled: Some("pi-widgets"),
            check_update_pi: &[],
            check_left: &["pi-widgets"],
            check_exit: 1,
        },
        Row {
            case: "a copy Pi loads from the personal scope since the run's snapshot",
            plant: |_, _| {},
            finish: &[UPDATE_PI],
            settle_with: &[UPDATE_PI],
            after: Some(loaded_from_the_personal_scope_now),
            unsettled: None,
            check_update_pi: &[],
            check_left: &["pi-widgets"],
            check_exit: 1,
        },
        Row {
            case: "a recorded copy whose source moved on, its personal-scope copy removed since the run",
            plant: moved_on_and_loaded_twice,
            finish: &[],
            settle_with: &[],
            after: Some(personal_copy_removed),
            unsettled: Some("pi-widgets"),
            check_update_pi: &["pi-widgets"],
            check_left: &[],
            check_exit: 1,
        },
        Row {
            case: "a recorded copy whose source moved on",
            plant: moved_on,
            finish: &[UPDATE_PI],
            settle_with: &[UPDATE_PI],
            after: None,
            unsettled: None,
            check_update_pi: &["pi-widgets"],
            check_left: &[],
            check_exit: 1,
        },
        Row {
            case: "a recorded copy whose source moved on, its update muted",
            plant: moved_on_and_muted,
            finish: &[UPDATE_PI],
            settle_with: &[UPDATE_PI],
            after: Some(the_mute_reached_the_snapshot),
            unsettled: None,
            check_update_pi: &["pi-widgets"],
            check_left: &[],
            check_exit: 1,
        },
        Row {
            case: "a manifest that no longer reads over a snapshot holding every Pi row class",
            plant: installed_and_recorded,
            finish: &[],
            settle_with: &[],
            after: Some(manifest_unreadable),
            unsettled: None,
            check_update_pi: &[],
            check_left: &[],
            check_exit: 2,
        },
    ];
    for row in rows {
        let (_tmp, home) = fixture();
        let project = home.join("dev/app");
        (row.plant)(&home, &project);

        let run = said(&kendex(&home, &project, &["apply", "--yes"]));
        let case = row.case;
        assert_eq!(keyed(&run, "finish-with"), row.finish, "{case}: {run}");
        assert_eq!(keyed(&run, "settle-with"), row.settle_with, "{case}: {run}");
        if let Some(name) = row.unsettled {
            assert!(run.contains(name), "{case}: {run}");
            assert!(!run.contains("up to date"), "{case}: {run}");
        }
        if let Some(after) = row.after {
            after(&home, &project);
        }
        let check = checked(&home, &project);
        assert_eq!(check.update_pi, row.check_update_pi, "{case}: check");
        assert_eq!(check.no_fix, row.check_left, "{case}: check");
        assert_eq!(check.exit, Some(row.check_exit), "{case}: check");
        let (plan_update_pi, plan_unsettled) = applied(&home, &project);
        assert_eq!(
            check.update_pi, plan_update_pi,
            "{case}: check against apply"
        );
        assert_eq!(check.no_fix, plan_unsettled, "{case}: check against apply");
        if check.exit == Some(0) {
            assert!(
                plan_update_pi.is_empty() && plan_unsettled.is_empty(),
                "{case}: check clean where apply leaves a Pi package"
            );
        }
        let (offered, warned) = standing(&home, &project);
        assert_eq!(offered, row.check_update_pi, "{case}: update standing");
        for name in row.check_left {
            assert!(
                warned.iter().any(|warned| warned == name),
                "{case}: {warned:?}"
            );
        }
        if let Some(name) = row.unsettled {
            let verified = said(&kendex(&home, &project, &["verify"]));
            assert!(
                !verified.contains(&format!("{name} — kendex update-pi records it")),
                "{case}: {verified}"
            );
        }
    }
}

/// `check` draws no Pi line from the snapshot: whatever Pi rows and notes
/// the last deep pass left, the scope's lines and exit code are the ones
/// its recorded snapshot gives. Each class is planted after the run, over
/// a recorded copy whose source moved on, which `check` names `update-pi`
/// for: no snapshot, a compare that failed and wrote only a note, a held
/// row, a muted row, a row whose source stopped offering it, an edited
/// row, and every flag and note at once beside a package never declared.
#[test]
#[allow(clippy::unwrap_used)]
fn the_snapshot_never_changes_a_pi_line() {
    use kendex_core::drift::snapshot::PackageSnapshot;
    let (_tmp, home) = fixture();
    let project = home.join("dev/app");
    kendex(&home, &project, &["apply", "--yes"]);
    let installed = kendex(&home, &project, &["update-pi", "--scope", "project"]);
    assert!(installed.status.success(), "{}", said(&installed));
    write(
        &project.join("catalog/pi-extensions/pi-widgets/index.js"),
        "export const version = 2;\n",
    );
    let run = kendex(&home, &project, &["apply", "--yes"]);
    assert!(run.status.success(), "{}", said(&run));
    let recorded = snapshot(&home, &project);
    let baseline = check_lines(&home, &project);
    assert_eq!(
        checked(&home, &project).update_pi,
        ["pi-widgets"],
        "the recorded snapshot's check names update-pi"
    );
    let without_pi = || {
        let mut snapshot = recorded.clone();
        snapshot
            .packages
            .retain(|row| row.kind != kendex_core::model::ItemKind::PiExtension);
        snapshot
            .unreadable
            .retain(|note| note.kind != kendex_core::model::ItemKind::PiExtension);
        snapshot
    };
    let with = |rows: Vec<PackageSnapshot>, notes: Vec<&str>| {
        let mut snapshot = without_pi();
        snapshot.packages.extend(rows);
        snapshot.unreadable.extend(notes.into_iter().map(pi_note));
        Some(snapshot)
    };
    let flagged = |name: &str| PackageSnapshot {
        update_available: true,
        removed_upstream: true,
        held: true,
        ignored: true,
        edited: true,
        mixed: true,
        ..pi_row(name)
    };
    let one = |row: PackageSnapshot| with(vec![row], vec![]);
    let every_class: Vec<PackageSnapshot> = ["pi-widgets", "pi-stray"]
        .into_iter()
        .flat_map(|name| {
            [
                flagged(name),
                PackageSnapshot {
                    update_available: true,
                    ..pi_row(name)
                },
                PackageSnapshot {
                    removed_upstream: true,
                    ..pi_row(name)
                },
                PackageSnapshot {
                    edited: true,
                    ..pi_row(name)
                },
                PackageSnapshot {
                    mixed: true,
                    ..pi_row(name)
                },
            ]
        })
        .collect();
    let classes: [(&str, Option<_>); 8] = [
        ("no snapshot", None),
        (
            "a failed compare's note and no row",
            with(vec![], vec!["pi-widgets"]),
        ),
        (
            "a held row",
            one(PackageSnapshot {
                update_available: true,
                held: true,
                ..pi_row("pi-widgets")
            }),
        ),
        (
            "a muted row",
            one(PackageSnapshot {
                update_available: true,
                ignored: true,
                ..pi_row("pi-widgets")
            }),
        ),
        (
            "a row no longer offered by its source",
            one(PackageSnapshot {
                removed_upstream: true,
                ..pi_row("pi-widgets")
            }),
        ),
        (
            "an edited row",
            one(PackageSnapshot {
                edited: true,
                ..pi_row("pi-widgets")
            }),
        ),
        ("a row with no update", one(pi_row("pi-widgets"))),
        (
            "every row class and note, beside an undeclared package",
            with(every_class, vec!["pi-widgets", "pi-stray"]),
        ),
    ];
    let env = kendex_core::env::Env::host_rooted(&home);
    for (class, planted) in classes {
        match &planted {
            Some(planted) => plant_snapshot(&home, &project, planted),
            None => {
                kendex_core::drift::snapshot::invalidate(&env, &project_scope(&project)).unwrap();
                assert!(matches!(
                    kendex_core::drift::snapshot::load(&env, &project_scope(&project)),
                    kendex_core::drift::snapshot::SnapshotFile::Absent
                ));
            }
        }
        assert_eq!(check_lines(&home, &project), baseline, "{class}");
    }
}

/// The gap line, with both kinds of gap under the one headline it has.
///
/// A plugin is recorded when the plan derives its toggle and skipped when
/// the harness cannot take one — here an older machine keeping Copilot's
/// settings in `config.json`. The Pi declaration beside it still writes the
/// record, so the file lands holding nothing while the scope asks for both:
/// a package no record ever holds, and one `apply` will record once that
/// machine changes its settings. The headline is true of the pair and each name says
/// which it is.
#[test]
#[allow(clippy::unwrap_used)]
fn verify_names_what_the_record_does_not_hold() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let manifest = env.global_manifest_file();
    write(
        &manifest,
        &format!("{MANIFEST}\n[plugins.\"fmt@main\"]\nenabled = true\nharness = \"copilot\"\n"),
    );
    // A global source path reads from the home directory.
    catalog(&home);
    write(&home.join(".copilot/config.json"), "{}\n");

    assert!(
        kendex(&home, &home, &["apply", "-g", "--yes"])
            .status
            .success()
    );
    let text = fs::read_to_string(env.global_lock_file()).unwrap();
    let record: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        record
            .get("entries")
            .and_then(serde_json::Value::as_object)
            .map(serde_json::Map::len),
        Some(0),
        "the record has to be there and hold nothing: {text}"
    );

    let checked = kendex(&home, &home, &["verify", "-g"]);

    assert!(
        !checked.status.success(),
        "unrecorded declarations must fail: {checked:?}"
    );
    assert_eq!(
        said(&checked).lines().collect::<Vec<_>>(),
        vec![
            "global: 2 packages listed and not in the install record",
            "  - pi-extension pi-widgets — kendex update-pi records it",
            "  - plugin fmt@main — kendex apply records it",
            "nothing checked",
        ]
    );
}

/// A plugin declares through a table of its own, carrying an enabled flag
/// and nothing else, so it reaches the gate through neither
/// `Manifest::declared` nor the expanded plan. It is still a scope asking
/// for something, and a scope asking for something with no record is the
/// state this verb measures without reporting success.
#[test]
#[allow(clippy::unwrap_used)]
fn verify_checks_a_plugin_only_scope_without_an_install_record() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    write(
        &project.join("kendex.toml"),
        "schema = 8\n\n[plugins.\"fmt@main\"]\nenabled = true\n",
    );
    assert!(!project.join(".kendex-lock.json").exists());

    let output = kendex(&home, &project, &["verify"]);

    assert!(!output.status.success(), "{output:?}");
    assert_eq!(
        said(&output).lines().next(),
        Some(
            format!(
                "! {}: no install record at {} — checking what this place lists against its installed files",
                kendex_core::paths::slashed(&project),
                project.join(".kendex-lock.json").display()
            )
            .as_str()
        )
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn verify_measures_matching_renders_when_the_lock_is_unreadable() {
    let (_tmp, home) = fixture();
    let project = home.join("dev/app");
    let lock = project.join(".kendex-lock.json");
    fs::write(&lock, "{\"version\":5}\n").unwrap();

    let output = kendex(&home, &project, &["verify", "--scope", "project"]);
    let text = said(&output);

    assert!(
        !output.status.success(),
        "the unreadable record still needs recovery"
    );
    assert!(text.contains("install record unreadable"), "{text}");
    assert!(
        text.contains("checking what this place lists against its installed files"),
        "{text}"
    );
    assert!(text.contains("✓ pi-extension pi-widgets [pi]"), "{text}");
    assert_eq!(fs::read_to_string(lock).unwrap(), "{\"version\":5}\n");
}
