//! Import fails closed (the #1307 class): a malformed v1 lock is never
//! treated as absent, and a live v2 install record is never re-imported
//! over.
#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex_in(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn project(home: &Path) -> std::path::PathBuf {
    let proj = home.join("proj");
    fs::create_dir_all(proj.join(".claude")).unwrap();
    proj
}

const V1_MANIFEST: &str = "[agent-skills]\nrust = [\"gh\"]\n";

#[test]
#[allow(clippy::unwrap_used)]
fn a_malformed_v1_lock_refuses_instead_of_reading_as_absent() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let proj = project(home);
    fs::write(proj.join("vstack.toml"), V1_MANIFEST).unwrap();
    // Damaged: not JSON at all. Treating it as absent would bury it under
    // a fresh empty v2 lock and lose the only record of what v1 installed.
    fs::write(proj.join(".vstack-lock.json"), "{not json").unwrap();

    let before = fs::read_to_string(proj.join(".vstack-lock.json")).unwrap();
    let output = kendex_in(home, &proj, &["import", "--scope", "project"]);
    assert!(!output.status.success(), "the import must refuse");
    let said = String::from_utf8_lossy(&output.stderr);
    assert!(
        said.contains("damaged") || said.contains("could not be read"),
        "{said}"
    );
    assert_eq!(
        fs::read_to_string(proj.join(".vstack-lock.json")).unwrap(),
        before,
        "nothing was overwritten"
    );
    assert_eq!(
        fs::read_to_string(proj.join("vstack.toml")).unwrap(),
        V1_MANIFEST,
        "the manifest was not half-migrated"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_stale_v1_lock_never_reimports_over_a_live_v2_record() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let proj = project(home);
    // The global scope keeps v1 and v2 locks at different paths, which is
    // exactly where a stale v1 leftover could shadow a live v2 record.
    #[cfg(target_os = "macos")]
    let config = home.join("Library/Application Support");
    #[cfg(not(target_os = "macos"))]
    let config = home.join(".config");
    let v1_dir = config.join("vstack");
    fs::create_dir_all(&v1_dir).unwrap();
    fs::write(
        v1_dir.join(".vstack-lock.json"),
        r#"{"version":1,"entries":{"old":{"name":"old","kind":"skill","source":"x/y","source_repo":"x/y","harnesses":["claude-code"],"method":"symlink","installed_at":"t","source_hash":"aa"}}}"#,
    )
    .unwrap();
    let v2_dir = config.join("kendex");
    fs::create_dir_all(&v2_dir).unwrap();
    fs::write(
        v2_dir.join("kendex.toml"),
        "schema = 5\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
    )
    .unwrap();
    let live_lock = r#"{"version":4,"entries":{"skill:current:claude":{"name":"current","kind":"skill","harness":"claude","source":"local","sourceRepo":"local","method":"symlink","installedAt":"t","sourceHash":"bb","enabled":true}}}"#;
    fs::write(v2_dir.join("lock.json"), live_lock).unwrap();

    let output = kendex_in(home, &proj, &["import", "--scope", "global"]);
    assert!(!output.status.success(), "the import must refuse");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("live v2 install record"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(v2_dir.join("lock.json")).unwrap(),
        live_lock,
        "current provenance survives untouched"
    );
}
