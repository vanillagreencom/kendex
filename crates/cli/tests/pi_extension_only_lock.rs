//! A scope that declares only Pi extensions still keeps an install record.
//!
//! A Pi extension derives no lock entry, so this scope's plan derives none
//! at all. The record still has to land: without it the verb reports the
//! scope up to date, nothing marks the project root for the walk-up that
//! prefers it, and nothing on disk states which build wrote the record. The
//! version floor's remedy for an older lock is to move the file aside,
//! which leaves exactly this shape.

#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

// Integration-test helpers sit outside #[test] fns, so clippy's
// allow-unwrap-in-tests does not reach them.
#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
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

/// A project whose manifest declares one Pi extension and nothing else, with
/// the package already installed and no lock file anywhere. Handed back with
/// the home the run reads, so a case never spells the root a second time.
#[allow(clippy::unwrap_used)]
fn fixture() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
    );
    let package = "{\n  \"name\": \"pi-widgets\",\n  \"version\": \"1.0.0\",\n  \"pi\": { \"extensions\": [\"index.js\"] }\n}\n";
    write(
        &project.join("catalog/pi-extensions/pi-widgets/package.json"),
        package,
    );
    write(
        &project.join("catalog/pi-extensions/pi-widgets/index.js"),
        "export const version = 1;\n",
    );
    write(
        &project.join(".pi/packages/pi-widgets/package.json"),
        package,
    );
    write(
        &project.join(".pi/packages/pi-widgets/index.js"),
        "export const version = 1;\n",
    );
    write(
        &project.join(".pi/settings.json"),
        "{\"packages\": [\"./packages/pi-widgets\"]}\n",
    );
    assert!(!project.join(".kendex-lock.json").exists());
    (tmp, home)
}

/// The version every record this build writes carries, read from the crate
/// rather than typed here: a floor bump is what strands a scope in the first
/// place, and a number copied into a test would go on asserting the old one.
const LOCK_VERSION: u32 = kendex_core::lock::LOCK_VERSION;

#[allow(clippy::unwrap_used)]
fn assert_record_landed(project: &Path) {
    let lock = project.join(".kendex-lock.json");
    assert!(lock.is_file(), "no install record at {}", lock.display());
    let text = fs::read_to_string(&lock).unwrap();
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        value.get("version").and_then(serde_json::Value::as_u64),
        Some(u64::from(LOCK_VERSION)),
        "{text}"
    );
}

/// Both halves of the write, and the state a person is actually left in.
///
/// The first run has to plan the record. The second has to plan nothing:
/// the restraint in `plan_lock_write` is the only thing between a scope
/// declaring a Pi extension and an "Update the install record" on every
/// run it ever gets, and a case that only ever drives a virgin fixture
/// cannot tell the two apart. `verify` closes it: the record is there, so
/// the run does not refuse, and the one declaration is named as what no
/// run of that verb checks.
#[test]
fn apply_writes_the_record_once_for_a_pi_extension_only_scope() {
    let (_tmp, home) = fixture();
    let project = home.join("dev/app");

    let first = said(&kendex(&home, &project, &["apply", "--yes"]));
    assert!(first.contains("Update the install record"), "{first}");
    assert!(!first.contains("up to date"), "{first}");
    assert_record_landed(&project);

    let second = said(&kendex(&home, &project, &["apply", "--yes"]));
    assert!(second.contains("up to date"), "{second}");
    assert!(!second.contains("Update the install record"), "{second}");
    assert_record_landed(&project);

    let checked = kendex(&home, &project, &["verify"]);
    assert!(checked.status.success(), "{checked:?}");
    assert_eq!(
        said(&checked).lines().collect::<Vec<_>>(),
        vec![
            format!(
                "{}: 1 item the install record never holds — kendex update-pi checks those",
                kendex_core::paths::slashed(&project)
            )
            .as_str(),
            "  - pi-extension pi-widgets",
            "nothing checked",
        ]
    );
}

#[test]
fn refresh_writes_the_record_for_a_pi_extension_only_scope() {
    let (_tmp, home) = fixture();
    let project = home.join("dev/app");

    let output = kendex(&home, &project, &["refresh", "--yes"]);

    assert!(output.status.success(), "{output:?}");
    let printed = said(&output);
    assert!(!printed.contains("up to date"), "{printed}");
    assert_record_landed(&project);
}

/// A declaration switched off is still a declaration. `enabled` rides on
/// the lock entry rather than deciding whether one exists, so the flag
/// decides nothing here — and the engine and `verify` have to agree about
/// that, which before the predicate was unified they did not: the record
/// was written and the verb reported the scope had nothing installed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_disabled_pi_extension_is_still_a_declaration() {
    let (_tmp, home) = fixture();
    let project = home.join("dev/app");
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    write(
        &project.join("kendex.toml"),
        &format!("{manifest}enabled = false\n"),
    );

    let first = said(&kendex(&home, &project, &["apply", "--yes"]));
    assert!(first.contains("Update the install record"), "{first}");
    assert_record_landed(&project);

    let second = said(&kendex(&home, &project, &["apply", "--yes"]));
    assert!(second.contains("up to date"), "{second}");

    let checked = kendex(&home, &project, &["verify"]);
    assert!(checked.status.success(), "{checked:?}");
    let printed = said(&checked);
    assert!(printed.contains("  - pi-extension pi-widgets"), "{printed}");
    assert!(!printed.contains("nothing installed"), "{printed}");
}

/// The scope asks for a package and has no record to weigh it against, so
/// the run closes on that rather than reporting a machine with nothing
/// installed on it. A pipeline running `kendex verify && deploy` after the
/// version floor's move-it-aside remedy reads the refusal, not a pass.
#[test]
fn verify_refuses_a_scope_with_no_install_record() {
    let (_tmp, home) = fixture();
    let project = home.join("dev/app");

    let output = kendex(&home, &project, &["verify"]);

    assert!(!output.status.success(), "{output:?}");
    let printed = said(&output);
    assert!(printed.contains("no install record"), "{printed}");
    assert!(!printed.contains("nothing installed"), "{printed}");
}

/// The global scope is the shape the bug was found on: Pi extensions
/// declared in `~/.config/kendex/kendex.toml`, and a lock the version
/// floor's remedy had moved aside. Its record sits under the app's own
/// directory and names no root, so it is a second path through the write,
/// not a second spelling of the same one.
#[test]
#[allow(clippy::unwrap_used)]
fn apply_writes_the_global_record_for_a_pi_extension_only_scope() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    // The layout this machine's build writes, asked for rather than spelled:
    // the global scope's directory is one the platform moves.
    let env = kendex_core::env::Env::host_rooted(&home);
    let manifest = env.global_manifest_file();
    let lock = env.global_lock_file();
    let global = manifest.parent().unwrap().to_path_buf();
    write(
        &manifest,
        "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
    );
    write(
        &global.join("catalog/pi-extensions/pi-widgets/package.json"),
        "{\n  \"name\": \"pi-widgets\",\n  \"version\": \"1.0.0\",\n  \"pi\": { \"extensions\": [\"index.js\"] }\n}\n",
    );
    write(
        &global.join("catalog/pi-extensions/pi-widgets/index.js"),
        "export const version = 1;\n",
    );
    assert!(!lock.exists());

    let output = kendex(&home, &home, &["apply", "-g", "--yes"]);

    assert!(output.status.success(), "{output:?}");
    let printed = said(&output);
    assert!(!printed.contains("up to date"), "{printed}");
    let text = fs::read_to_string(&lock).unwrap();
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        value.get("version").and_then(serde_json::Value::as_u64),
        Some(u64::from(LOCK_VERSION)),
        "{text}"
    );
}
