//! `refresh`, `check` and `verify` over an in-place skill whose tree the
//! person has edited since `apply`: each passes, because the tree is the
//! source. The inverses are what verify still fails: the entry point gone,
//! and a harness link gone.
//!
//! The must-fail control for the green rows is the engine before this
//! surface: an edited tree moved the recorded source hash, so verify failed
//! each harness row and the record row.
#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::process::Hardened;

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("KENDEX_UI", "plain")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let home = dir.to_str().unwrap();
    let out = Hardened::git(args, Some(dir))
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .run()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

struct World {
    _tmp: tempfile::TempDir,
    home: PathBuf,
    project: PathBuf,
}

impl World {
    fn skill_file(&self) -> PathBuf {
        self.project.join(".agents/skills/deploy/SKILL.md")
    }

    fn run(&self, args: &[&str]) -> Output {
        kendex(&self.home, &self.project, args)
    }

    fn exit_code(&self, args: &[&str]) -> i32 {
        let out = self.run(args);
        out.status
            .code()
            .unwrap_or_else(|| panic!("kendex {args:?} ended on a signal: {}", said(&out)))
    }
}

/// A project holding one in-place skill under project instructions,
/// applied once, so the tree carries the block and the record the links.
#[allow(clippy::unwrap_used)]
fn applied() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("app");
    let source = project.join(".agents/skills/deploy");
    fs::create_dir_all(&source).unwrap();
    fs::write(
        source.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nOwned source.\n",
    )
    .unwrap();
    fs::write(source.join("reference.md"), "step one\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[skill-instructions]\nall = \"shared rule\"\n\n[install]\nharnesses = [\"claude\", \"codex\", \"pi\"]\nmethod = \"symlink\"\n\n[skills.deploy]\nsource = \"in-place\"\n",
    )
    .unwrap();
    git(&project, &["init", "-q", "-b", "main"]);
    let world = World {
        _tmp: tmp,
        home,
        project,
    };
    let out = world.run(&[
        "apply",
        "--yes",
        "--scope",
        "project",
        "--throwaway",
        "--leave",
    ]);
    assert!(out.status.success(), "{}", said(&out));
    world
}

/// The three verbs after an edit to the tree: refresh has nothing to do
/// and leaves the record as it was, check is clean, verify passes every
/// row.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_in_place_skill_passes_refresh_check_and_verify() {
    let world = applied();
    let lock = world.project.join(".kendex-lock.json");
    let recorded = fs::read_to_string(&lock).unwrap();
    let mut skill = fs::read_to_string(world.skill_file()).unwrap();
    skill.push_str("Another edit.\n");
    fs::write(world.skill_file(), &skill).unwrap();
    fs::write(
        world.project.join(".agents/skills/deploy/reference.md"),
        "step one\nstep two\n",
    )
    .unwrap();

    let refresh = world.run(&[
        "refresh",
        "--yes",
        "--scope",
        "project",
        "--throwaway",
        "--leave",
    ]);
    assert!(refresh.status.success(), "{}", said(&refresh));
    assert!(said(&refresh).contains("up to date"), "{}", said(&refresh));
    assert_eq!(fs::read_to_string(&lock).unwrap(), recorded);
    assert_eq!(fs::read_to_string(world.skill_file()).unwrap(), skill);

    let check = world.run(&["check", "--scope", "project"]);
    assert_eq!(check.status.code(), Some(0), "{}", said(&check));

    let verify = world.run(&["verify", "--scope", "project"]);
    assert_eq!(verify.status.code(), Some(0), "{}", said(&verify));
    assert!(
        said(&verify).contains("3 checked, 3 OK, 0 failed"),
        "{}",
        said(&verify)
    );
}

/// What verify still fails: the entry point kendex renders from, and the
/// link a tool reads the tree through.
#[test]
#[allow(clippy::unwrap_used)]
fn verify_fails_a_missing_entry_point_and_a_missing_link() {
    let world = applied();
    assert_eq!(world.exit_code(&["verify", "--scope", "project"]), 0);

    let skill = fs::read(world.skill_file()).unwrap();
    fs::remove_file(world.skill_file()).unwrap();
    assert_eq!(world.exit_code(&["verify", "--scope", "project"]), 1);
    fs::write(world.skill_file(), skill).unwrap();
    assert_eq!(world.exit_code(&["verify", "--scope", "project"]), 0);

    fs::remove_file(world.project.join(".claude/skills/deploy")).unwrap();
    assert_eq!(world.exit_code(&["verify", "--scope", "project"]), 1);
}
