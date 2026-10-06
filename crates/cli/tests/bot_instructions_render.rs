//! `kendex bot-instructions-render`, the verb a consumer refresh calls: the
//! installed package's render, run once with no setup record, its streams and
//! exit status relayed as the package wrote them.
#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::process::Hardened;

const DECLARATION: &str = "---\nname: bot-instructions\ndescription: fixture review rules\nrepo-effects:\n  summary: \"Renders the fixture review file in this repository.\"\n  writes:\n    - \".github/copilot-instructions.md\"\n  installer: \"scripts/bot-instructions render\"\n  checker: \"scripts/bot-instructions check\"\n---\nFixture.\n";

/// Writes the review file and says so on stdout, as the package's render does.
const RENDERS: &str = "#!/bin/sh\nmkdir -p .github\necho rules >.github/copilot-instructions.md\necho 'wrote .github/copilot-instructions.md'\n";

/// Refuses as the package does for a manifest with no `[bot-instructions]`.
const REFUSES: &str = "#!/bin/sh\necho 'bot-instructions: unconfigured=kendex.toml' >&2\necho 'no table' >&2\nexit 2\n";

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let out = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

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

/// A repository that installs the fixture package from a catalog inside it,
/// for the claude harness, so the copy sits in a harness directory. Nobody
/// set it up: the install runs with no terminal and no consent flag.
#[allow(clippy::unwrap_used)]
fn installed(home: &Path, launcher: &str) -> PathBuf {
    let project = home.join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[sources.cat]\npath = \"catalog\"\n\n[skills.bot-instructions]\nsource = \"cat\"\n",
    );
    let package = project.join("catalog/skills/bot-instructions");
    write(&package.join("SKILL.md"), DECLARATION);
    let script = package.join("scripts/bot-instructions");
    write(&script, launcher);
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
    git(&project, &["init", "-q", "-b", "main"]);
    let applied = kendex(home, &project, &["apply", "--yes", "--leave"]);
    assert!(
        applied.status.success(),
        "{}",
        String::from_utf8_lossy(&applied.stderr)
    );
    fs::remove_file(project.join(".github/copilot-instructions.md")).ok();
    project
}

#[allow(clippy::unwrap_used)]
fn armed(project: &Path) -> bool {
    let repo = kendex_core::guard::Repo::at(project).unwrap();
    kendex_core::repo_effects::armed::recorded(
        kendex_core::repo_effects::armed::record_dir(&repo, false),
        "bot-instructions",
    )
    .unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_render_runs_where_nobody_set_the_package_up_and_records_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp).join("home");
    let project = installed(&home, RENDERS);
    assert!(
        !project.join(".agents/skills/bot-instructions").exists(),
        "the fixture meant a copy in the harness directory"
    );

    let ran = kendex(&home, &project, &["bot-instructions-render"]);
    assert_eq!(ran.status.code(), Some(0));
    assert!(
        String::from_utf8_lossy(&ran.stdout)
            .lines()
            .any(|line| line == "wrote .github/copilot-instructions.md")
    );
    assert!(project.join(".github/copilot-instructions.md").exists());
    assert!(!armed(&project), "the run wrote a setup record");
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_package_refusal_comes_back_with_its_status() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp).join("home");
    let project = installed(&home, REFUSES);

    let ran = kendex(&home, &project, &["bot-instructions-render"]);
    assert_eq!(ran.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&ran.stderr)
            .lines()
            .any(|line| line == "bot-instructions: unconfigured=kendex.toml"),
        "{}",
        String::from_utf8_lossy(&ran.stderr)
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_project_without_the_package_says_it_is_absent() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp).join("home");
    let project = home.join("dev/app");
    write(
        &project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n",
    );
    fs::create_dir_all(project.join(".claude")).unwrap();
    git(&project, &["init", "-q", "-b", "main"]);

    let ran = kendex(&home, &project, &["bot-instructions-render"]);
    assert_eq!(ran.status.code(), Some(0));
    assert_eq!(
        String::from_utf8_lossy(&ran.stdout).trim_end(),
        "bot-instructions-render=absent"
    );
}
