//! The authoring verbs end to end through the binary: create, register,
//! list — the non-interactive spellings of the Mine tab's flows.
#![cfg(unix)]

use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(home)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[test]
#[allow(clippy::unwrap_used)]
fn new_scaffolds_and_mine_lists_the_row() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let dir = home.join("team-skills");
    let output = kendex(
        home,
        &[
            "marketplace",
            "new",
            "team-skills",
            "--description",
            "Skills for the team",
            "--author",
            "Jane Doe",
            "--license",
            "mit",
            "--dir",
            dir.to_str().unwrap(),
        ],
    );
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(output.status.success(), "{said}");
    assert!(dir.join("kendex.toml").exists());
    assert!(dir.join("LICENSE").exists());
    assert!(dir.join(".github/workflows/kendex-check.yml").exists());
    assert!(said.contains("0 breakage"), "{said}");

    let mine = kendex(home, &["marketplace", "mine"]);
    assert!(mine.status.success());
    let listed = String::from_utf8_lossy(&mine.stdout).into_owned();
    assert!(listed.contains("team-skills"), "{listed}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn use_registers_a_discovered_repo_without_writing_into_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let repo = home.join("their-repo");
    let skill = repo.join(".claude/skills/review");
    std::fs::create_dir_all(&skill).unwrap();
    std::fs::write(
        skill.join("SKILL.md"),
        "---\nname: review\ndescription: reviews\n---\nBody.\n",
    )
    .unwrap();

    let output = kendex(home, &["marketplace", "use", repo.to_str().unwrap()]);
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(output.status.success(), "{said}");
    assert!(said.contains("nothing inside it was changed"), "{said}");
    assert!(
        !repo.join("kendex.toml").exists(),
        "use-existing must not write a control file"
    );

    let mine = kendex(home, &["marketplace", "mine", "--json"]);
    let json: serde_json::Value = serde_json::from_slice(&mine.stdout).unwrap();
    let rows = json["marketplaces"].as_array().unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["counts"]["skill"], 1);
    assert_eq!(rows[0]["declared"], false);
}

#[test]
#[allow(clippy::unwrap_used)]
fn import_with_no_selections_lists_candidates_and_exits_clean() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let target = home.join("mine");
    std::fs::create_dir_all(&target).unwrap();
    let output = kendex(
        home,
        &["marketplace", "import", target.to_str().unwrap(), "--json"],
    );
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(output.status.success(), "{said}");
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(json["schema"], 1);
    assert!(json["candidates"].as_array().unwrap().is_empty());
}
