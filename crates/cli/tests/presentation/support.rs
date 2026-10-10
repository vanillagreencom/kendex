//! The support verbs at the process boundary: streams, modes, wrapping,
//! refusal and the plain report protocol. Login's browser approval view
//! is tested beside its renderer without using a person's keychain.

use super::*;

#[allow(clippy::unwrap_used)]
fn run(args: &[&str], extra: &[(&str, &str)]) -> (bool, String, String) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("project");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(project.join("kendex.toml"), "schema = 7\n").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(&project)
        .env_clear()
        .envs(test_util::fixture_env(&home))
        .env("LANG", "C.UTF-8")
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .envs(extra.iter().copied())
        .output()
        .unwrap();
    let normalize =
        |bytes: &[u8]| String::from_utf8_lossy(bytes).replace(&home.display().to_string(), "HOME");
    (
        output.status.success(),
        normalize(&output.stdout),
        normalize(&output.stderr),
    )
}

#[test]
fn support_modes_keep_streams_and_plain_protocol() {
    for args in [
        vec!["init", "tidy", "--kind", "skill"],
        vec!["init"],
        vec!["init", "tidy", "--kind", "unknown"],
        vec![
            "report",
            "--title",
            "Broken",
            "--body",
            "Details",
            "--dry-run",
        ],
        vec!["report", "--title", "Broken"],
    ] {
        let piped = run(&args, &[]);
        for env in [
            vec![("KENDEX_UI", "plain")],
            vec![("KENDEX_UI", "pretty"), ("NO_COLOR", "1")],
            vec![("KENDEX_UI", "pretty"), ("TERM", "dumb")],
        ] {
            assert_eq!(run(&args, &env), piped, "{args:?}, {env:?}");
        }
        let rich = run(&args, &[("KENDEX_UI", "pretty"), ("COLUMNS", "80")]);
        assert_eq!(rich.0, piped.0, "rendering changed the exit: {args:?}");
        assert!(
            rich.1.contains('\u{1b}') || rich.2.contains('\u{1b}'),
            "no rich rendering: {args:?}"
        );
        assert!(
            !piped.1.contains('\u{1b}') && !piped.2.contains('\u{1b}'),
            "plain escapes: {args:?}"
        );
    }
    let created = run(&["init", "tidy", "--kind", "skill"], &[]);
    assert_eq!(
        created,
        (
            true,
            "created HOME/project/skills/tidy/SKILL.md\n".into(),
            String::new()
        )
    );
    let report = run(
        &[
            "report",
            "--title",
            "Broken",
            "--body",
            "Details",
            "--dry-run",
        ],
        &[],
    );
    assert_eq!(
        report,
        (
            true,
            String::new(),
            concat!(
                "warning: no asset selector — routing to this project's own repo\n",
                "ownership: project-local\n",
                "target: current repo origin\n",
                "would run: gh issue create --title Broken --body Details\n",
            )
            .into()
        )
    );
    assert_eq!(
        run(&["report", "--title", "Broken"], &[]),
        (
            false,
            String::new(),
            "Error: provide --body or --body-file\n".into(),
        )
    );
}

#[test]
fn support_prose_wraps_at_eighty_columns() {
    let name = "this-package-name-is-deliberately-long-so-that-the-created-file-message-needs-to-wrap-at-the-terminal-width";
    let args = ["init", name, "--kind", "skill"];
    let plain = run(&args, &[]);
    let rich = run(&args, &[("KENDEX_UI", "pretty"), ("COLUMNS", "80")]);
    assert!(
        plain
            .1
            .lines()
            .any(|line| console::measure_text_width(line) > 80)
    );
    for stream in [&rich.1, &rich.2] {
        for line in stream.lines() {
            assert!(
                console::measure_text_width(line) <= 80,
                "too wide: {line:?}"
            );
        }
    }
}

#[test]
fn help_opens_with_the_description_at_the_binary() {
    let help = run(&["--help"], &[]);
    assert!(help.0 && help.2.is_empty());
    assert!(
        help.1
            .starts_with("Install and manage packages for your AI coding harnesses.\n\nUsage:")
    );
    assert!(!help.1.contains("CommitFlags::from_matches"));
    assert_eq!(
        run(&["help", "report"], &[]),
        run(&["report", "--help"], &[])
    );
}
