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
            "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\", \"pi\"]\n",
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
            "schema = 7\n[sources.cat]\nrepo = {repo:?}\n[install]\nharnesses = [\"claude\"]\n"
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

/// The person's own edit to an installed style: Claude's selection set to
/// another style, or the words inside Pi's block.
type Edit = fn(&Path);

#[allow(clippy::unwrap_used, reason = "fixture edit")]
fn select_another(project: &Path) {
    let path = project.join(".claude/settings.json");
    let mut settings: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(settings["outputStyle"], "STE", "kendex never selected STE");
    settings["outputStyle"] = "Explanatory".into();
    fs::write(&path, settings.to_string()).unwrap();
}

#[allow(clippy::unwrap_used, reason = "fixture edit")]
fn reword_the_block(project: &Path) {
    let path = project.join(".pi/APPEND_SYSTEM.md");
    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains("Write short sentences."), "{text}");
    fs::write(
        &path,
        text.replace("Write short sentences.", "My own instructions."),
    )
    .unwrap();
}

/// An edited style ends no run and is no edit the updates listing offers
/// to keep as a fork or discard: a run with no terminal over it exits 0
/// and names nothing on a `skipped-on-conflict=` line, the line automation
/// keys on, `kendex check --report-only` exits 0, and the edit stays.
#[test]
#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn an_edited_style_is_kept_and_ends_no_run() {
    let temp = tempfile::tempdir().unwrap();
    let fresh = rooted(&temp);
    // Re-execution gives Env::detect the same sandbox opt-out and platform
    // roots as the CLI child, for the in-process updates listing.
    let home = match std::env::var_os("KENDEX_TEST_OUTPUT_STYLE_HOME") {
        Some(home) => PathBuf::from(home),
        None => {
            let home = fresh;
            let mut environment = fixture_env(&home).to_vec();
            environment.push(("KENDEX_TEST_OUTPUT_STYLE_HOME", home.into_os_string()));
            environment.push(("PATH", std::env::var_os("PATH").unwrap_or_default()));
            let output = reexecute_test(
                module_path!(),
                "an_edited_style_is_kept_and_ends_no_run",
                &environment,
            )
            .unwrap();
            assert!(output.status.success(), "{output:?}");
            return;
        }
    };
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("output-styles")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(catalog.join("output-styles/STE.md"), "---\nname: STE\ndescription: Short sentences\nkeep-coding-instructions: true\n---\nWrite short sentences.\n").unwrap();
    git(&catalog, &["init", "--quiet", "-b", "main"]);
    git(&catalog, &["add", "."]);
    git(&catalog, &["commit", "--quiet", "-m", "style"]);
    let repo = url::Url::from_directory_path(&catalog).unwrap().to_string();
    let env = Env::detect().unwrap();
    let rows: [(&str, &str, Edit); 2] = [
        ("claude-selection", "claude", select_another),
        ("pi-block", "pi", reword_the_block),
    ];
    for (case, harness, edit) in rows {
        let project = home.join(case);
        fs::create_dir_all(project.join(format!(".{harness}"))).unwrap();
        fs::write(
            project.join("kendex.toml"),
            format!(
                "schema = 7\n[sources.cat]\nrepo = {repo:?}\n[install]\nharnesses = [\"{harness}\"]\n"
            ),
        )
        .unwrap();
        let add = ["add", "--output-style", "STE", "--yes", "--leave"];
        let added = kendex(&home, &project, &add);
        assert!(added.status.success(), "{case}: {added:?}");
        edit(&project);
        let edited = fs::read(project.join(format!(".{harness}")).join(match harness {
            "claude" => "settings.json",
            _ => "APPEND_SYSTEM.md",
        }))
        .unwrap();

        for args in [&["apply", "--yes", "--leave"][..], &add[..]] {
            let output = kendex(&home, &project, args);
            let printed = String::from_utf8_lossy(&output.stderr);
            assert_eq!(output.status.code(), Some(0), "{case} {args:?}: {printed}");
            assert!(
                !printed.contains("skipped-on-conflict="),
                "{case} {args:?}: {printed}"
            );
        }
        // The check reads the comparison with sources this listing writes.
        let listed = kendex(&home, &project, &["updates"]);
        assert!(listed.status.success(), "{case}: {listed:?}");
        let checked = kendex(&home, &project, &["check", "--report-only"]);
        assert_eq!(checked.status.code(), Some(0), "{case}: {checked:?}");
        let scope = kendex_core::model::Scope::Project {
            root: project.clone(),
        };
        let rows = kendex_core::package::updates::updates(&env, &scope)
            .unwrap()
            .rows;
        let row = rows
            .iter()
            .find(|row| row.kind == ItemKind::OutputStyle && row.name == "STE")
            .unwrap_or_else(|| panic!("{case}: no updates row for STE"));
        // `can_discard` holds for every row whose source resolved; the
        // discard and fork offers stand on the edit flag beside it.
        assert!(
            !row.blocked_by_local_edit && row.edited_harnesses.is_empty(),
            "{case}: {row:?}"
        );
        let kept = fs::read(project.join(format!(".{harness}")).join(match harness {
            "claude" => "settings.json",
            _ => "APPEND_SYSTEM.md",
        }))
        .unwrap();
        assert_eq!(kept, edited, "{case}: the edit was not kept");
    }
}
