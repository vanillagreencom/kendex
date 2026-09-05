//! Fixture installs keep account records separate while honoring explicit XDG roots.
#![cfg(target_os = "linux")]

#[path = "../../test_util.rs"]
mod test_util;

use kendex_core::env::Env;
use kendex_core::lock::Lock;
use std::path::{Path, PathBuf};
use std::process::Command;
use test_util::rooted;

#[allow(clippy::unwrap_used)]
fn catalog(root: &Path) -> PathBuf {
    let catalog = root.join("catalog");
    std::fs::create_dir_all(catalog.join("skills/fixture-skill")).unwrap();
    std::fs::write(
        catalog.join("kendex.toml"),
        "[marketplace]\nname = \"fixture\"\n",
    )
    .unwrap();
    std::fs::write(
        catalog.join("skills/fixture-skill/SKILL.md"),
        "---\nname: fixture-skill\ndescription: fixture installation\n---\nFixture.\n",
    )
    .unwrap();
    catalog
}

#[allow(clippy::unwrap_used)]
fn install_command(home: &Path, catalog: &Path) -> Command {
    std::fs::create_dir_all(home).unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .args(["add"])
        .arg(catalog)
        .args([
            "--global",
            "--skill",
            "fixture-skill",
            "--harness",
            "claude",
            "--copy",
            "--yes",
        ])
        .current_dir(home)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap());
    command
}

#[allow(clippy::unwrap_used)]
fn assert_installed(lock_path: &Path, home: &Path) {
    let lock: Lock = serde_json::from_slice(&std::fs::read(lock_path).unwrap()).unwrap();
    let entry = lock
        .entries
        .values()
        .find(|entry| entry.name == "fixture-skill")
        .unwrap();
    let emitted = entry.emitted.as_ref().unwrap();
    assert!(!emitted.paths.is_empty());
    for path in &emitted.paths {
        assert!(
            path.starts_with(home),
            "{} escaped the fixture",
            path.display()
        );
        assert!(path.exists(), "{} was not installed", path.display());
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_fixture_install_preserves_the_inherited_global_lock() {
    let temp = tempfile::tempdir().unwrap();
    let root = rooted(&temp);
    let owner = root.join("owner");
    let fixture = root.join("fixture");
    let owner_env = Env::host_rooted(&owner);
    let fixture_env = Env::host_rooted(&fixture);
    let owner_lock = owner_env.global_lock_file();
    std::fs::create_dir_all(owner_lock.parent().unwrap()).unwrap();
    kendex_core::lock::save(&owner_lock, &Lock::default()).unwrap();
    let original = std::fs::read(&owner_lock).unwrap();
    let mut command = install_command(&fixture, &catalog(&root));
    // Simulated inherited account paths remain private even if isolation fails.
    command
        .env(
            "XDG_CONFIG_HOME",
            owner_lock.parent().unwrap().parent().unwrap(),
        )
        .env(
            "XDG_CACHE_HOME",
            owner_env
                .app_update_cache_file()
                .parent()
                .unwrap()
                .parent()
                .unwrap(),
        )
        .env(
            "XDG_DATA_HOME",
            owner_env
                .installed_command_file()
                .parent()
                .unwrap()
                .parent()
                .unwrap(),
        );
    let output = command
        .envs(test_util::fixture_env(&fixture))
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(
        std::fs::read(&owner_lock).unwrap(),
        original,
        "fixture install rewrote the inherited global lock"
    );
    assert_installed(&fixture_env.global_lock_file(), &fixture);
    assert!(!owner_env.source_cache_dir().exists());
    assert!(!owner_env.journal_dir().exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_explicit_custom_xdg_root_still_receives_the_global_lock() {
    let temp = tempfile::tempdir().unwrap();
    let root = rooted(&temp);
    let fixture = root.join("fixture");
    let custom = root.join("custom");
    let custom_env = Env::host_rooted(&custom);
    let output = install_command(&fixture, &catalog(&root))
        .envs(test_util::fixture_env(&fixture))
        .envs(
            test_util::fixture_env(&custom)
                .into_iter()
                .filter(|(key, _)| *key != "HOME"),
        )
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_installed(&custom_env.global_lock_file(), &fixture);
    assert!(!Env::host_rooted(&fixture).global_lock_file().exists());
}
