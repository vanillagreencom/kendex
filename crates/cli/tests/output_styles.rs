//! The output-style add flag and content-based verification through the CLI.

use crate::test_util::{fixture_env, rooted, source_path};
use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::unwrap_used, reason = "fixture process execution")]
fn kendex(home: &Path, project: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(project)
        .env_clear()
        .envs(fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .output()
        .unwrap()
}

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn add_installs_the_style_and_verify_fails_on_a_hand_edit() {
    let temp = tempfile::tempdir().unwrap();
    let home = rooted(&temp);
    let project = home.join("project");
    let catalog = home.join("catalog");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(project.join(".pi")).unwrap();
    fs::create_dir_all(catalog.join("output-styles")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(catalog.join("output-styles/STE.md"), "---\nname: STE\ndescription: Short sentences\nkeep-coding-instructions: true\n---\nWrite short sentences.\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\", \"pi\"]\n",
            source_path(&catalog)
        ),
    )
    .unwrap();
    let added = kendex(&home, &project, &["add", "--output-style", "STE", "--yes"]);
    assert!(
        added.status.success(),
        "{}",
        String::from_utf8_lossy(&added.stderr)
    );
    let verified = kendex(&home, &project, &["verify", "--scope", "project"]);
    assert!(
        verified.status.success(),
        "{}{}",
        String::from_utf8_lossy(&verified.stdout),
        String::from_utf8_lossy(&verified.stderr)
    );
    for target in [
        project.join(".claude/output-styles/STE.md"),
        project.join(".pi/APPEND_SYSTEM.md"),
    ] {
        let original = fs::read_to_string(&target).unwrap();
        fs::write(
            &target,
            original.replace("Write short sentences.", "My own instructions."),
        )
        .unwrap();
        let failed = kendex(&home, &project, &["verify", "--scope", "project"]);
        assert!(
            !failed.status.success(),
            "hand edit at {} passed verify",
            target.display()
        );
        fs::write(&target, original).unwrap();
    }
}
