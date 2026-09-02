//! The install record a scope keeps when the plan derives no entry for what
//! it declares, and what `verify` says about the gap.
//!
//! A Pi extension derives no lock entry, so a scope declaring only those
//! derives none at all. The record still has to land: without it the verb
//! reports the scope up to date, nothing marks the project root for the
//! walk-up that prefers it, and nothing on disk states which build wrote the
//! record. The version floor's remedy for an older lock is to move the file
//! aside, which leaves exactly this shape.

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

const MANIFEST: &str = "schema = 6\n\n[sources.cat]\npath = \"catalog\"\n\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n";
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
/// asserting the old one.
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
/// tell the two apart. `verify` closes it — the record is there, so the run
/// does not refuse, and the declaration is named as one no record holds.
///
/// The global scope is where this was found and is a second path through the
/// write, its record sitting under the app's own directory and naming no
/// root, so it is driven here rather than left to the project spelling.
#[test]
#[allow(clippy::unwrap_used)]
fn apply_writes_the_record_once_for_a_pi_extension_only_scope() {
    let (_tmp, home) = fixture();
    let project = home.join("dev/app");

    let first = said(&kendex(&home, &project, &["apply", "--yes"]));
    assert!(first.contains("Update the install record"), "{first}");
    assert!(!first.contains("up to date"), "{first}");
    assert_record_landed(&project.join(".kendex-lock.json"));

    let second = said(&kendex(&home, &project, &["apply", "--yes"]));
    assert!(second.contains("up to date"), "{second}");
    assert!(!second.contains("Update the install record"), "{second}");

    let checked = kendex(&home, &project, &["verify", "--scope", "project"]);
    assert!(checked.status.success(), "{checked:?}");
    assert_eq!(
        said(&checked).lines().collect::<Vec<_>>(),
        vec![
            format!(
                "{}: 1 item declared and not in the install record",
                kendex_core::paths::slashed(&project)
            )
            .as_str(),
            "  - pi-extension pi-widgets — no record ever holds one; kendex update-pi checks it",
            "nothing checked",
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

/// The gap line, with both kinds of gap under the one headline it has.
///
/// A plugin is recorded when the plan derives its toggle and skipped when
/// the harness cannot take one — here an older machine keeping Copilot's
/// settings in `config.json`. The Pi declaration beside it still writes the
/// record, so the file lands holding nothing while the scope asks for both:
/// a package no record ever holds, and one `apply` will record once that
/// machine migrates. The headline is true of the pair and each name says
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
    catalog(manifest.parent().unwrap());
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

    assert!(checked.status.success(), "{checked:?}");
    assert_eq!(
        said(&checked).lines().collect::<Vec<_>>(),
        vec![
            "global: 2 items declared and not in the install record",
            "  - pi-extension pi-widgets — no record ever holds one; kendex update-pi checks it",
            "  - plugin fmt@main — kendex apply records it",
            "nothing checked",
        ]
    );
}

/// A plugin declares through a table of its own, carrying an enabled flag
/// and nothing else, so it reaches the gate through neither
/// `Manifest::declared` nor the expanded plan. It is still a scope asking
/// for something, and a scope asking for something with no record is the
/// state this verb refuses.
#[test]
#[allow(clippy::unwrap_used)]
fn verify_refuses_a_plugin_only_scope_with_no_install_record() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[plugins.\"fmt@main\"]\nenabled = true\n",
    );
    assert!(!project.join(".kendex-lock.json").exists());

    let output = kendex(&home, &project, &["verify"]);

    assert!(!output.status.success(), "{output:?}");
    assert_eq!(
        said(&output).lines().next(),
        Some(
            format!(
                "! {}: no install record at {} — this scope was not checked",
                kendex_core::paths::slashed(&project),
                project.join(".kendex-lock.json").display()
            )
            .as_str()
        )
    );
}
