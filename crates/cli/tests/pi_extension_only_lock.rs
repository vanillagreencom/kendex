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

#[test]
fn apply_writes_the_record_for_a_pi_extension_only_scope() {
    let (_tmp, home) = fixture();
    let project = home.join("dev/app");

    let output = kendex(&home, &project, &["apply", "--yes"]);

    assert!(output.status.success(), "{output:?}");
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!said.contains("up to date"), "{said}");
    assert_record_landed(&project);
}

#[test]
fn refresh_writes_the_record_for_a_pi_extension_only_scope() {
    let (_tmp, home) = fixture();
    let project = home.join("dev/app");

    let output = kendex(&home, &project, &["refresh", "--yes"]);

    assert!(output.status.success(), "{output:?}");
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!said.contains("up to date"), "{said}");
    assert_record_landed(&project);
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
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(said.contains("no install record"), "{said}");
    assert!(!said.contains("nothing installed"), "{said}");
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
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!said.contains("up to date"), "{said}");
    let text = fs::read_to_string(&lock).unwrap();
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        value.get("version").and_then(serde_json::Value::as_u64),
        Some(u64::from(LOCK_VERSION)),
        "{text}"
    );
}
