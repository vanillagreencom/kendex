//! Output-style installation, shared kind commands and content verification.

use crate::test_util::{fixture_env, git, reexecute_test, rooted, source_path};
use kendex_core::env::Env;
use kendex_core::model::ItemKind;
use std::fs;
use std::path::{Path, PathBuf};
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

#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn installed_style_reaches_shared_package_commands() {
    let temp = tempfile::tempdir().unwrap();
    // Re-execution gives Env::detect the same sandbox opt-out and platform
    // roots as the CLI child, including Windows known-folder selection.
    let home = match std::env::var_os("KENDEX_TEST_OUTPUT_STYLE_HOME") {
        Some(home) => PathBuf::from(home),
        None => {
            let home = rooted(&temp);
            let mut environment = fixture_env(&home).to_vec();
            environment.push(("KENDEX_TEST_OUTPUT_STYLE_HOME", home.into_os_string()));
            environment.push(("PATH", std::env::var_os("PATH").unwrap_or_default()));
            let output = reexecute_test(
                module_path!(),
                "installed_style_reaches_shared_package_commands",
                &environment,
            )
            .unwrap();
            assert!(output.status.success(), "{output:?}");
            return;
        }
    };
    let project = home.join("project");
    let catalog = home.join("catalog");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(catalog.join("output-styles")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    let content = "---\nname: STE\ndescription: Short sentences\nkeep-coding-instructions: true\n---\nWrite short sentences.\n";
    fs::write(catalog.join("output-styles/STE.md"), content).unwrap();
    git(&catalog, &["init", "--quiet", "-b", "main"]);
    git(&catalog, &["add", "."]);
    git(&catalog, &["commit", "--quiet", "-m", "style"]);
    let commit = git(&catalog, &["rev-parse", "HEAD"]);
    let commit = commit.trim();
    let repo = url::Url::from_directory_path(&catalog).unwrap().to_string();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n[sources.cat]\nrepo = {repo:?}\n[install]\nharnesses = [\"claude\"]\n"
        ),
    )
    .unwrap();
    let added = kendex(&home, &project, &["add", "--output-style", "STE", "--yes"]);
    assert!(
        added.status.success(),
        "{}",
        String::from_utf8_lossy(&added.stderr)
    );
    assert_eq!(
        fs::read_to_string(project.join(".claude/output-styles/STE.md")).unwrap(),
        content
    );

    for (args, expected) in [
        (vec!["show", "output-style", "STE", "--files"], "STE.md"),
        (vec!["versions", "output-style", "STE"], &commit[..7]),
        (
            vec![
                "diff",
                "output-style",
                "STE",
                "--from",
                commit,
                "--to",
                commit,
            ],
            "no changes",
        ),
    ] {
        let output = kendex(&home, &project, &args);
        let printed = String::from_utf8_lossy(&output.stderr);
        assert!(
            output.status.success() && printed.contains(expected),
            "{args:?}: {printed}"
        );
    }
    for (revision, held) in [(commit, Some(commit)), ("--follow", None)] {
        let args = ["pin", "output-style", "STE", revision, "--yes"];
        let output = kendex(&home, &project, &args);
        assert!(output.status.success(), "{args:?}: {output:?}");
        let manifest = kendex_core::manifest::load_for_mutation(&project.join("kendex.toml"))
            .unwrap()
            .unwrap();
        assert_eq!(manifest.output_styles["STE"].rev.as_deref(), held);
    }
    let env = Env::detect().unwrap();
    for (verb, ignored) in [("ignore", true), ("unignore", false)] {
        let output = kendex(&home, &project, &["updates", verb, "output-style", "STE"]);
        assert!(
            output.status.success(),
            "{verb}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let settings = kendex_core::settings::load(&env).unwrap();
        assert_eq!(
            settings
                .ignored_updates
                .iter()
                .any(|entry| entry.kind == ItemKind::OutputStyle
                    && entry.name == "STE"
                    && entry.repo == repo),
            ignored
        );
    }
}
