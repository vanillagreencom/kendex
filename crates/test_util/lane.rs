//! Neutral git worktrees shared by the marker reader and CLI suites.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[allow(dead_code, reason = "test binaries share the fixture library")]
pub struct Fixture {
    _tmp: tempfile::TempDir,
    pub root: PathBuf,
    pub main: PathBuf,
    pub linked: PathBuf,
    pub marker: PathBuf,
    item: String,
}

impl Fixture {
    #[allow(
        dead_code,
        clippy::expect_used,
        reason = "test binaries share this setup; a fixture failure must fail its test"
    )]
    pub fn new(item: &str) -> Self {
        let tmp = tempfile::tempdir().expect("fixture directory");
        let root = super::rooted(&tmp);
        let main = root.join("main");
        let linked = root.join("linked");
        fs::create_dir(&main).expect("main checkout directory");
        let mut fixture = Self {
            _tmp: tmp,
            root,
            main,
            linked,
            marker: PathBuf::new(),
            item: item.to_owned(),
        };
        fixture.git(&fixture.main, &["init", "-q", "-b", "main"]);
        fixture.git(&fixture.main, &["config", "gc.auto", "0"]);
        fixture.git(&fixture.main, &["config", "maintenance.auto", "false"]);
        fixture.git(&fixture.main, &["commit", "-qm", "seed", "--allow-empty"]);
        fixture.git(
            &fixture.main,
            &[
                "worktree",
                "add",
                "-qb",
                item,
                fixture.linked.to_str().expect("fixture path"),
            ],
        );
        fixture.marker = fixture
            .main
            .join(".git/lane-mail")
            .join(item.to_ascii_lowercase());
        fixture
    }

    #[allow(
        dead_code,
        clippy::expect_used,
        reason = "test binaries share this process setup; a missing PATH must fail its test"
    )]
    pub fn command(&self, program: impl AsRef<std::ffi::OsStr>, cwd: &Path) -> Command {
        let mut command = Command::new(program);
        command
            .current_dir(cwd)
            .env_clear()
            .envs(super::fixture_env(&self.root))
            .env("PATH", std::env::var_os("PATH").expect("test PATH"))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("KENDEX_BACKGROUND_REFRESH", "off")
            .env("KENDEX_UI", "plain");
        command
    }

    #[allow(
        dead_code,
        clippy::expect_used,
        reason = "test binaries share this git setup; a failed launch must fail its test"
    )]
    pub fn git(&self, cwd: &Path, args: &[&str]) {
        let output = self
            .command("git", cwd)
            .args(["-c", "user.name=test", "-c", "user.email=test@example.com"])
            .args(args)
            .output()
            .expect("fixture git runs");
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    /// Use orch's actual producer, not a test spelling of its record.
    #[allow(
        dead_code,
        clippy::expect_used,
        reason = "test binaries share this marker setup; a failed launch must fail its test"
    )]
    pub fn mark(&self) {
        let output = self
            .command("bash", &self.linked)
            .arg(super::checkout_root().join(".agents/skills/orch/scripts/lane-marker"))
            .arg(&self.linked)
            .arg(&self.item)
            .output()
            .expect("lane-marker runs");
        assert!(
            output.status.success(),
            "lane-marker: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[derive(Debug, PartialEq, Eq)]
#[allow(dead_code, reason = "test binaries share the snapshot library")]
pub enum Entry {
    Directory,
    File(Vec<u8>),
    Link(PathBuf),
}

/// Include empty directories and links, as well as file bytes. A refusal
/// must not create even an empty cache or first-run record directory.
#[allow(
    dead_code,
    clippy::expect_used,
    reason = "test binaries share this snapshot; an incomplete read must fail its test"
)]
pub fn snapshot(root: &Path) -> BTreeMap<PathBuf, Entry> {
    let mut entries = BTreeMap::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(path) = pending.pop() {
        let metadata = fs::symlink_metadata(&path).expect("snapshot metadata");
        let entry = if metadata.is_symlink() {
            Entry::Link(fs::read_link(&path).expect("snapshot link"))
        } else if metadata.is_dir() {
            pending.extend(
                fs::read_dir(&path)
                    .expect("snapshot directory")
                    .map(|entry| entry.expect("snapshot directory entry").path()),
            );
            Entry::Directory
        } else {
            Entry::File(fs::read(&path).expect("snapshot file"))
        };
        entries.insert(
            path.strip_prefix(root)
                .expect("snapshot containment")
                .to_path_buf(),
            entry,
        );
    }
    entries
}
