//! Claude needs no generated instruction file. Apply retires recorded
//! former shims and keeps personal files. Gemini still verifies its key.
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
    let project = home.join("dev/project with spaces in its directory name");
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
fn apply_and_verify_need_no_claude_instruction_file() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    let nested = project.join("crates/core");
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("AGENTS.md"), "# core\n").unwrap();
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "-q", "-m", "nested"]);

    for args in [
        vec!["apply", "--plan"],
        vec!["apply", "--yes"],
        vec!["verify", "--scope", "project"],
    ] {
        let output = kendex(&home, &project, &args);
        assert!(output.status.success(), "{}", said(&output));
        assert!(!said(&output).contains("CLAUDE.md"));
        assert!(!project.join("CLAUDE.md").exists());
        assert!(!nested.join("CLAUDE.md").exists());
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn apply_retires_recorded_claude_files_and_keeps_personal_files() {
    for (bytes, listed, linked, retired) in [
        ("@AGENTS.md\n", true, false, true),
        ("@AGENTS.md\n# mine\n", true, false, false),
        ("@AGENTS.md\n", true, true, false),
        ("@AGENTS.md\n", false, false, false),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        let output = kendex(&home, &project, &["apply", "--yes"]);
        assert!(output.status.success(), "{}", said(&output));
        let path = project.join("CLAUDE.md");
        if linked {
            fs::write(project.join("personal.md"), bytes).unwrap();
            std::os::unix::fs::symlink("personal.md", &path).unwrap();
        } else {
            fs::write(&path, bytes).unwrap();
        }
        if listed {
            let inventory = project.join(".kendex-generated.json");
            fs::write(inventory, "[\"CLAUDE.md\"]\n").unwrap();
        }
        let output = kendex(&home, &project, &["apply", "--yes", "--replace-unmanaged"]);
        assert!(output.status.success(), "{}", said(&output));
        assert_eq!(path.exists(), !retired);
        if !retired {
            assert_eq!(fs::read_to_string(&path).unwrap(), bytes);
            assert_eq!(path.is_symlink(), linked);
            assert!(!said(&output).contains("CLAUDE.md"));
        }
        for args in [
            vec!["apply", "--plan"],
            vec!["verify", "--scope", "project"],
        ] {
            let output = kendex(&home, &project, &args);
            assert!(output.status.success(), "{}", said(&output));
            assert!(!said(&output).contains("CLAUDE.md"));
        }
    }
}

/// A record laid out as kendex writes it but without the Gemini shim, as a
/// build predating the field writes it again while Gemini is installed and
/// in sync, fails the record row by the shim's name; the next apply
/// records the shim and the row passes. Nothing else fails: the shim and
/// every other position stand as before.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_that_lost_its_gemini_shim_fails_verify_until_apply() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"gemini\"]\n",
    )
    .unwrap();
    let output = kendex(&home, &project, &["apply", "--yes"]);
    assert!(output.status.success(), "{}", said(&output));
    let output = kendex(&home, &project, &["verify", "--scope", "project"]);
    assert!(output.status.success(), "{}", said(&output));

    let lock_path = project.join(".kendex-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    assert_eq!(lock["shims"], serde_json::json!(["gemini-context-file"]));
    lock.as_object_mut().unwrap().remove("shims");
    fs::write(
        &lock_path,
        format!("{}\n", serde_json::to_string_pretty(&lock).unwrap()),
    )
    .unwrap();

    let output = kendex(&home, &project, &["verify", "--scope", "project"]);
    let text = said(&output);
    assert!(!output.status.success(), "{text}");
    assert!(
        text.contains("shim gemini-context-file: kept, and the record does not carry it"),
        "{text}"
    );
    assert!(!text.contains("not laid out as kendex writes it"), "{text}");
    assert!(text.contains("1 other row failed"), "{text}");

    let output = kendex(&home, &project, &["apply", "--yes"]);
    assert!(output.status.success(), "{}", said(&output));
    let output = kendex(&home, &project, &["verify", "--scope", "project"]);
    assert!(output.status.success(), "{}", said(&output));
}

/// Gemini off the list in a project with no repository of its own, the
/// record still carrying the shim: whether the retirement still has the
/// shim's entry to take (`planned`) or the person already took it out
/// (`settled`), the record row alone fails verify, by the shim's name,
/// until the next apply writes the record again and leaves the person's
/// own keys.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_carrying_a_retired_gemini_shim_fails_verify_until_apply() {
    let theirs = "{\n  \"ui\": {\n    \"theme\": \"Dark\"\n  }\n}\n";
    for (what, person_took_the_entry) in [("planned", false), ("settled", true)] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = home.join("outside/app");
        fs::create_dir_all(project.join(".gemini")).unwrap();
        fs::write(project.join("AGENTS.md"), "# app\n").unwrap();
        let settings = project.join(".gemini/settings.json");
        fs::write(&settings, theirs).unwrap();
        let declare = |harnesses: &str| {
            fs::write(
                project.join("kendex.toml"),
                format!("schema = 6\n\n[install]\nharnesses = [{harnesses}]\n"),
            )
            .unwrap();
        };
        let parsed = |text: &str| serde_json::from_str::<serde_json::Value>(text).unwrap();
        declare("\"codex\", \"gemini\"");
        let output = kendex(&home, &project, &["apply", "--yes"]);
        assert!(output.status.success(), "{what}: {}", said(&output));
        assert!(!project.join(".kendex-generated.json").exists(), "{what}");
        assert_ne!(
            parsed(&fs::read_to_string(&settings).unwrap()),
            parsed(theirs),
            "{what}: the shim's entry stands"
        );
        let lock: serde_json::Value =
            parsed(&fs::read_to_string(project.join(".kendex-lock.json")).unwrap());
        assert_eq!(
            lock["shims"],
            serde_json::json!(["gemini-context-file"]),
            "{what}"
        );

        if person_took_the_entry {
            fs::write(&settings, theirs).unwrap();
        }
        declare("\"codex\"");

        let output = kendex(&home, &project, &["verify", "--scope", "project"]);
        let text = said(&output);
        assert!(!output.status.success(), "{what}: {text}");
        assert!(
            text.contains("shim gemini-context-file: recorded, and this pass does not keep it"),
            "{what}: {text}"
        );
        assert!(text.contains("1 other row failed"), "{what}: {text}");

        let output = kendex(&home, &project, &["apply", "--yes"]);
        assert!(output.status.success(), "{what}: {}", said(&output));
        assert_eq!(
            parsed(&fs::read_to_string(&settings).unwrap()),
            parsed(theirs),
            "{what}"
        );
        let output = kendex(&home, &project, &["verify", "--scope", "project"]);
        assert!(output.status.success(), "{what}: {}", said(&output));
    }
}
