//! VST-255: `vstack add` without `-y` in a non-TTY session must fail with an
//! actionable message — not crossterm's bare "No such device or address
//! (os error 6)" — and must leave the global source registry untouched.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Sandboxes live under CARGO_TARGET_TMPDIR, not the OS temp dir: the source
/// registry refuses to remember OS-temp sources, so a sandbox there would
/// mask a leaked registry write.
fn unique_target_tmp_dir(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("vstack-{name}-{}-{nanos}", std::process::id()))
}

fn write_fixture_source(source: &Path) {
    fs::create_dir_all(source.join("skills/demo")).unwrap();
    fs::write(
        source.join("skills/demo/SKILL.md"),
        "---\nname: demo\ndescription: Demo skill\n---\n# Demo\n",
    )
    .unwrap();
}

struct Sandbox {
    root: PathBuf,
    source: PathBuf,
    project: PathBuf,
    home: PathBuf,
    xdg: PathBuf,
}

impl Sandbox {
    fn new(name: &str) -> Self {
        let root = unique_target_tmp_dir(name);
        let source = root.join("source");
        let project = root.join("project");
        let home = root.join("home");
        let xdg = root.join("xdg");
        fs::create_dir_all(&project).unwrap();
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&xdg).unwrap();
        write_fixture_source(&source);
        Self {
            root,
            source,
            project,
            home,
            xdg,
        }
    }

    fn registry_path(&self) -> PathBuf {
        self.xdg.join("vstack").join("sources.json")
    }

    /// `Command::output()` nulls stdin and pipes stdout/stderr, so the child
    /// runs with no TTY on any stream — the VST-255 repro environment.
    fn vstack(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_vstack"));
        command
            .current_dir(&self.project)
            .env("HOME", &self.home)
            .env("XDG_CONFIG_HOME", &self.xdg);
        command
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn assert_actionable_failure(output: &std::process::Output) {
    assert!(
        !output.status.success(),
        "non-TTY add without -y must exit non-zero\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("needs a terminal"),
        "error must name the missing terminal: {stderr}"
    );
    assert!(stderr.contains("-y"), "error must name the -y fix: {stderr}");
    assert!(
        stderr.contains("--harness"),
        "error must name --harness: {stderr}"
    );
    assert!(
        !stderr.contains("os error 6"),
        "raw ENXIO must not leak: {stderr}"
    );
}

#[test]
fn add_without_yes_in_non_tty_fails_actionably_and_leaves_registry_untouched() {
    let sandbox = Sandbox::new("non-tty-add");
    // Seed sources.json in a non-canonical byte form (compact, no trailing
    // newline, remote-only entries so load-time dead-path pruning cannot
    // rewrite it): any registry save at all changes the bytes.
    let reg_path = sandbox.registry_path();
    fs::create_dir_all(reg_path.parent().unwrap()).unwrap();
    let seeded: &[u8] = br#"{"current":null,"entries":["vanillagreencom/vstack"]}"#;
    fs::write(&reg_path, seeded).unwrap();

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .output()
        .unwrap();

    assert_actionable_failure(&output);
    assert_eq!(
        fs::read(&reg_path).unwrap(),
        seeded,
        "a failed non-TTY add must leave sources.json byte-identical"
    );
    assert!(
        !sandbox.project.join(".vstack-lock.json").exists(),
        "a failed non-TTY add must install nothing"
    );
}

#[test]
fn add_without_yes_in_non_tty_does_not_create_a_registry() {
    let sandbox = Sandbox::new("non-tty-add-fresh");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .output()
        .unwrap();

    assert_actionable_failure(&output);
    assert!(
        !sandbox.registry_path().exists(),
        "a failed non-TTY add must not create sources.json"
    );
}
