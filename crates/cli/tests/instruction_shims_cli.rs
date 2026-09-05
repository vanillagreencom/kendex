//! The instruction shims on the CLI: `verify` prints one row per shim and
//! fails on one out of sync, `apply --plan` previews the write in plain
//! words, and `apply` writes it.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
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
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .run()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// A repository declaring the claude harness, its root `AGENTS.md`
/// committed, nothing else declared.
#[allow(clippy::unwrap_used)]
fn project(tmp: &tempfile::TempDir) -> PathBuf {
    let home = rooted(tmp);
    let project = home.join("dev/app");
    // The harness directory is what marks a project for the verbs run in
    // it; git and the manifest alone do not.
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n",
    )
    .unwrap();
    fs::write(project.join("AGENTS.md"), "# app\n").unwrap();
    fs::write(project.join(".gitignore"), "/.kendex-lock.json\n").unwrap();
    git(&project, &["init", "-q", "-b", "main"]);
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "files"]);
    project
}

#[test]
#[allow(clippy::unwrap_used)]
fn verify_names_the_shim_and_apply_writes_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);

    let output = kendex(&home, &project, &["verify", "--scope", "project"]);
    let text = said(&output);
    assert!(!output.status.success(), "{text}");
    assert!(text.contains("✗ shim CLAUDE.md [claude]"), "{text}");
    assert!(text.contains("not written yet"), "{text}");
    assert!(text.contains("nothing installed"), "{text}");

    let output = kendex(&home, &project, &["apply", "--plan"]);
    let text = said(&output);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("Write the Claude Code shim"), "{text}");
    assert!(!project.join("CLAUDE.md").exists());

    let output = kendex(&home, &project, &["apply", "--yes"]);
    assert!(output.status.success(), "{}", said(&output));
    assert_eq!(
        fs::read_to_string(project.join("CLAUDE.md")).unwrap(),
        "@AGENTS.md\n"
    );

    let output = kendex(&home, &project, &["verify", "--scope", "project"]);
    let text = said(&output);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("✓ shim CLAUDE.md [claude]"), "{text}");
}

/// A hand-written file is a conflict on both verbs, and `apply --plan`
/// names the flag that takes it over.
#[test]
#[allow(clippy::unwrap_used)]
fn a_foreign_shim_fails_verify_and_blocks_apply() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    fs::write(project.join("CLAUDE.md"), "# mine\n").unwrap();

    let output = kendex(&home, &project, &["verify", "--scope", "project"]);
    let text = said(&output);
    assert!(!output.status.success(), "{text}");
    assert!(
        text.contains("✗ shim CLAUDE.md [claude]: CLAUDE.md is not the shim"),
        "{text}"
    );

    let output = kendex(&home, &project, &["apply", "--plan"]);
    let text = said(&output);
    assert!(
        text.contains("conflict: skill CLAUDE.md for Claude Code: CLAUDE.md is not the shim"),
        "{text}"
    );
    assert!(text.contains("--replace-unmanaged"), "{text}");
    assert_eq!(
        fs::read_to_string(project.join("CLAUDE.md")).unwrap(),
        "# mine\n"
    );

    let output = kendex(&home, &project, &["apply", "--yes", "--replace-unmanaged"]);
    assert!(output.status.success(), "{}", said(&output));
    assert_eq!(
        fs::read_to_string(project.join("CLAUDE.md")).unwrap(),
        "@AGENTS.md\n"
    );
}
