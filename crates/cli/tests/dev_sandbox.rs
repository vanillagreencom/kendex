//! Windows is out of scope here: `dirs::data_dir()` reads a Known Folder
//! there, so neither the fixture HOME nor the XDG overrides below reach it
//! and the child would write into the real profile. The sandbox itself
//! holds on Windows — this is the test that cannot be pointed somewhere
//! safe, not the behaviour.
#![cfg(not(windows))]

use std::path::{Path, PathBuf};
use std::process::Command;

fn find(dir: &Path, name: &str) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if let Some(hit) = find(&path, name) {
                return Some(hit);
            }
        } else if path.file_name().is_some_and(|f| f == name) {
            return Some(path);
        }
    }
    None
}

/// The guarantee the sandbox exists for: a build from a branch writes to its
/// own home, never to the one it was handed. Helper-level tests cannot see
/// this — it takes the real binary, the real `dirs` resolution and the debug
/// profile together.
#[test]
fn a_debug_build_writes_to_the_dev_home_not_the_one_it_was_given() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&project).expect("project dir");
    std::fs::write(project.join("kendex.toml"), "").expect("manifest");

    let out = Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(["project", "add"])
        .arg(&project)
        .env("HOME", &home)
        // Empty is not an opt-in — this test is the sandboxed case.
        .env("KENDEX_REAL_HOME", "")
        .env("XDG_DATA_HOME", home.join(".local/share"))
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("XDG_CACHE_HOME", home.join(".cache"))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("run kendex");
    assert!(out.status.success(), "{out:?}");

    let data = match cfg!(target_os = "macos") {
        true => home.join("Library/Application Support"),
        false => home.join(".local/share"),
    };
    let sandbox = data.join("kendex-dev");
    assert!(
        find(&sandbox, "settings.toml").is_some(),
        "nothing landed under {}",
        sandbox.display()
    );
    for escaped in [home.join(".config/kendex"), data.join("kendex")] {
        assert!(
            !escaped.exists(),
            "{} — a sandboxed build wrote to the home it was given",
            escaped.display()
        );
    }
}
