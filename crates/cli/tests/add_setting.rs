//! `kendex add --setting KEY=VALUE`: the flag reaches the settings pass,
//! whose rules `kendex-core`'s `settings_seed::supplied` suite holds, and a
//! value that is not KEY=VALUE is refused before anything is read.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        // No case here resolves a collection link: a run that tried would
        // meet a closed local port rather than the share service.
        .env("KENDEX_API", "http://127.0.0.1:9")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

/// A project subscribed to a catalog whose one skill declares a key it
/// does not mark `# required`, so only the flag can put it in the file.
#[allow(clippy::unwrap_used)]
fn project(home: &Path) -> std::path::PathBuf {
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let skill = home.join("catalog/skills/links");
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        "---\nname: links\ndescription: shares files between worktrees\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        skill.join("kendex.settings.toml.example"),
        "[env]\n# Paths each worktree links to the main checkout.\nWORKTREE_SYMLINKS = \"\"\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            source_path(&home.join("catalog"))
        ),
    )
    .unwrap();
    project
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_setting_flag_writes_its_value_split_at_the_first_equals_sign() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&home);

    let output = kendex(
        &home,
        &project,
        &[
            "add",
            "--skill",
            "links",
            "--setting",
            "WORKTREE_SYMLINKS=.cache a=b",
            "-y",
        ],
    );
    assert!(
        output.status.success(),
        "add failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let settings = fs::read_to_string(project.join("kendex.settings.toml")).unwrap();
    assert!(
        settings.contains("WORKTREE_SYMLINKS = \".cache a=b\""),
        "{settings}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_setting_without_an_equals_sign_is_refused_before_anything_is_written() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&home);
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();

    let output = kendex(
        &home,
        &project,
        &[
            "add",
            "--skill",
            "links",
            "--setting",
            "WORKTREE_SYMLINKS",
            "-y",
        ],
    );
    assert_eq!(output.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("WORKTREE_SYMLINKS is not KEY=VALUE"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(project.join("kendex.toml")).unwrap(),
        manifest
    );
    assert!(!project.join("kendex.settings.toml").exists());
}

/// A collection link installs the set it resolves to and takes no
/// settings, so a value given beside one is refused before the link is
/// resolved rather than dropped.
#[test]
#[allow(clippy::unwrap_used)]
fn a_setting_beside_a_collection_link_is_refused_before_the_link_is_read() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&home);
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();

    let output = kendex(
        &home,
        &project,
        &[
            "add",
            "https://kendex.ai/c/abcdefgh12345678",
            "--setting",
            "WORKTREE_SYMLINKS=.cache",
            "-y",
        ],
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "{stderr}");
    assert!(
        stderr.contains("a collection link installs its own set"),
        "{stderr}"
    );
    assert_eq!(
        fs::read_to_string(project.join("kendex.toml")).unwrap(),
        manifest
    );
    assert!(!project.join("kendex.settings.toml").exists());
}
