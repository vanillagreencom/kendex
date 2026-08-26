//! The install/adopt journeys, end to end on throwaway repositories.
//!
//! Everything here runs the real binary against a fixture HOME with a real
//! git repository under it, because the promises being checked are about
//! what is on disk after a command and what a *second* machine sees when it
//! clones that disk. A unit test can prove a link is planned; only a clone
//! can prove the link resolves once the absolute paths it was written on
//! are gone.
//!
//! Windows is out of scope: committed symlinks need Developer Mode there,
//! and copy delivery is the documented answer rather than something these
//! scenarios can assert.
#![cfg(unix)]

mod adopting;
mod cloning;
mod coexistence;
mod guarding;
mod installing;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// The binary, pointed at a fixture home it must treat as real — without
/// `KENDEX_REAL_HOME` a debug build sandboxes itself into the dev home and
/// every assertion below would be about the wrong machine.
#[allow(clippy::expect_used)]
pub fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .output()
        .expect("kendex binary runs")
}

/// A command that must succeed, with the tool's own words on the failure.
#[allow(clippy::expect_used)]
pub fn run(home: &Path, cwd: &Path, args: &[&str]) -> String {
    let output = kendex(home, cwd, args);
    assert!(
        output.status.success(),
        "kendex {args:?} failed:\n{}",
        said(&output)
    );
    said(&output)
}

pub fn said(output: &Output) -> String {
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    text
}

/// git with the caller's environment dropped: run from a commit hook, the
/// inherited `GIT_DIR` would send every command at the repository being
/// committed to instead of the fixture.
#[allow(clippy::unwrap_used)]
pub fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_PREFIX")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// A fixture home holding a local catalog and an empty git project, with
/// the harnesses named here looking installed on the machine.
pub struct World {
    pub tmp: tempfile::TempDir,
    pub home: PathBuf,
    pub project: PathBuf,
    pub catalog: PathBuf,
}

#[allow(clippy::unwrap_used)]
impl World {
    /// `detected` names the harnesses whose global directory exists, which
    /// is what kendex's own detection reads.
    pub fn new(detected: &[&str]) -> World {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().to_path_buf();
        let catalog = home.join("catalog");
        write(
            &catalog.join("skills/deploy/SKILL.md"),
            "---\nname: deploy\ndescription: ship the service\n---\nRun the deploy.\n",
        );
        write(
            &catalog.join("skills/deploy/reference.md"),
            "The long version.\n",
        );
        for harness in detected {
            fs::create_dir_all(home.join(global_root(harness))).unwrap();
        }
        let project = home.join("dev/app");
        // `.agents` is a project marker, and a repository adopting the
        // shared convention has it before kendex ever runs.
        fs::create_dir_all(project.join(".agents")).unwrap();
        git(&project, &["init", "--quiet", "-b", "main"]);
        write(&project.join("README.md"), "the app\n");
        git(&project, &["add", "."]);
        git(&project, &["commit", "--quiet", "-m", "start"]);
        World {
            tmp,
            home,
            project,
            catalog,
        }
    }

    /// The project declaring the fixture catalog as a source, with no items
    /// yet — what `kendex add` would have written on its own.
    pub fn declare_catalog(&self) {
        write(
            &self.project.join("kendex.toml"),
            &format!(
                "schema = 6\n\n[sources.cat]\npath = \"{}\"\n",
                self.catalog.display()
            ),
        );
    }

    pub fn run(&self, args: &[&str]) -> String {
        run(&self.home, &self.project, args)
    }

    pub fn try_run(&self, args: &[&str]) -> Output {
        kendex(&self.home, &self.project, args)
    }

    pub fn at(&self, rel: &str) -> PathBuf {
        self.project.join(rel)
    }

    pub fn manifest(&self) -> String {
        fs::read_to_string(self.at("kendex.toml")).unwrap_or_default()
    }

    /// Commit everything the working tree holds, so a clone of it can be
    /// asked what a teammate would get.
    pub fn commit_all(&self, message: &str) {
        git(&self.project, &["add", "-A"]);
        git(&self.project, &["commit", "--quiet", "-m", message]);
    }
}

/// Where a harness's global directory sits under a fixture home. Detection
/// reads exactly these, so creating one is how a scenario says "this
/// machine has that tool".
fn global_root(harness: &str) -> &'static str {
    match harness {
        "claude" => ".claude",
        "codex" => ".codex",
        "cursor" => ".cursor",
        "gemini" => ".gemini",
        "opencode" => ".config/opencode",
        "copilot" => ".copilot",
        "pi" => ".pi/agent",
        other => panic!("unknown harness {other}"),
    }
}

#[allow(clippy::unwrap_used)]
pub fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
pub fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The text a link holds, exactly as it was written — the whole point of
/// the committed posture is that this is relative.
#[allow(clippy::unwrap_used)]
pub fn link_text(path: &Path) -> String {
    assert!(path.is_symlink(), "{} is not a link", path.display());
    fs::read_link(path).unwrap().display().to_string()
}

/// Every path under `root`, relative and sorted — for asserting that a
/// command left a neighbouring tree exactly as it found it.
#[allow(clippy::unwrap_used)]
pub fn tree(root: &Path) -> Vec<String> {
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let rel = path.strip_prefix(root).unwrap().display().to_string();
            if path.is_dir() && !path.is_symlink() {
                stack.push(path);
                found.push(format!("{rel}/"));
            } else {
                found.push(rel);
            }
        }
    }
    found.sort();
    found
}
