//! Windows is out of scope here: `dirs::data_dir()` reads a Known Folder
//! there, so neither the fixture HOME nor the XDG overrides below reach it
//! and the child would write into the real profile. The sandbox itself
//! holds on Windows — this is the test that cannot be pointed somewhere
//! safe, not the behaviour.
//!
//! A release build is not sandboxed, which is the point, so these assertions
//! are false for one and the file is compiled only into a debug test run.
//! `cargo test --release` is how the release is verified, and a debug-only
//! guarantee asserted there fails a build that is behaving correctly.
#![cfg(all(not(windows), debug_assertions))]

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

/// A debug build pointed at a fixture home, with the platform dirs sent
/// there too so `dirs` cannot reach the real machine.
fn kendex(home: &Path) -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_kendex"));
    cmd.env("HOME", home)
        // Empty is not an opt-in — these tests are the sandboxed case.
        .env("KENDEX_REAL_HOME", "")
        .env("XDG_DATA_HOME", home.join(".local/share"))
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("XDG_CACHE_HOME", home.join(".cache"))
        .env("PATH", std::env::var("PATH").unwrap_or_default());
    cmd
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

    let out = kendex(&home)
        .args(["project", "add"])
        .arg(&project)
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

/// A sandbox moves where this build writes, not where the person lives.
/// Discovery walks up from the cwd and refuses to call the home itself a
/// project; hand it the sandbox home instead and the real home stops being
/// that boundary, so a `~/.claude` is all it takes for the home to look
/// like a project and take every project write.
#[test]
fn a_sandboxed_build_still_knows_the_real_home_is_not_a_project() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    // The marker that makes an ordinary home look like a project.
    std::fs::create_dir_all(home.join(".claude")).expect("marker");
    let cwd = home.join("scratch");
    std::fs::create_dir_all(&cwd).expect("cwd");

    let out = kendex(&home)
        .args(["apply", "--scope", "project", "--yes"])
        .current_dir(&cwd)
        .output()
        .expect("run kendex");

    let said =
        String::from_utf8_lossy(&out.stdout).into_owned() + &String::from_utf8_lossy(&out.stderr);
    assert!(
        said.contains("not inside a project"),
        "the home was taken for a project: {said}"
    );
    assert!(
        !home.join("kendex.toml").exists(),
        "a sandboxed build wrote a manifest into the real home"
    );
}
