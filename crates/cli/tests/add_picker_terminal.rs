//! The questions `add` asks at a terminal, driven through a pseudoterminal
//! by their keys: which tools a package installs to, and how it is
//! delivered. `src/commands/harness_picker/tests.rs` holds how each is
//! drawn.
#![cfg(unix)]

use crate::pty;
use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::Path;
use std::process::Command;

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// One run: where stderr goes, each answer with the marker it waits for,
/// the exit code, and what the run declared.
struct Run {
    what: &'static str,
    stderr: fn() -> pty::Stderr,
    steps: &'static [(&'static str, &'static str)],
    code: i32,
    /// The tools and delivery `tidy` is declared with, or `None` where the
    /// run wrote nothing.
    declared: Option<(&'static [&'static str], &'static str)>,
}

/// Claude Code is on the machine, so it comes checked. `2` checks Codex and
/// Enter installs to both; `c` copies; `y` is the write consent. Escape at
/// either question cancels before anything is written. With stderr on a
/// pipe the same answers are typed lines.
#[test]
#[allow(clippy::unwrap_used)]
fn the_tools_and_the_delivery_are_picked_by_their_keys() {
    let terminal = || pty::Stderr::Terminal;
    let runs = [
        Run {
            what: "keys",
            stderr: terminal,
            steps: &[
                ("[2] add Codex", "2"),
                ("[2] drop Codex", "\n"),
                ("[c] copy", "c"),
                ("[y] yes", "y"),
            ],
            code: 0,
            declared: Some((&["claude", "codex"], "copy")),
        },
        Run {
            what: "typed lines, stderr on a pipe",
            stderr: || pty::Stderr::Pipe,
            steps: &[
                ("[2] add Codex", "2\n"),
                ("[2] drop Codex", "\n"),
                ("[c] copy", "c\n"),
                ("[y] yes", "y\n"),
            ],
            code: 0,
            declared: Some((&["claude", "codex"], "copy")),
        },
        Run {
            what: "cancel at the tools",
            stderr: terminal,
            steps: &[("[Enter] install to Claude Code", "\x1b")],
            code: 130,
            declared: None,
        },
        Run {
            what: "cancel at the delivery",
            stderr: terminal,
            steps: &[
                ("[Enter] install to Claude Code", "\n"),
                ("[c] copy", "\x1b"),
            ],
            code: 130,
            declared: None,
        },
    ];
    for run in runs {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        fs::create_dir_all(home.join(".claude")).unwrap();
        let catalog = home.join("catalog");
        write(
            &catalog.join("skills/tidy/SKILL.md"),
            "---\nname: tidy\ndescription: tidy up\n---\nTidy.\n",
        );
        let project = home.join("dev/app");
        let manifest = format!("schema = 6\n\n[sources.cat]\n{}\n", source_path(&catalog));
        write(&project.join("kendex.toml"), &manifest);
        let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
        command
            .args(["add", "--skill", "tidy"])
            .current_dir(&project)
            .env_clear()
            .envs(test_util::fixture_env(&home))
            .env("KENDEX_BACKGROUND_REFRESH", "off")
            .env("KENDEX_UI", "plain")
            .env("PATH", std::env::var("PATH").unwrap_or_default());

        let output = pty::conversation(command, run.steps, (run.stderr)());

        let text = String::from_utf8_lossy(&output.stderr).into_owned();
        let what = run.what;
        assert_eq!(output.status.code(), Some(run.code), "{what}:\n{text}");
        let written = fs::read_to_string(project.join("kendex.toml")).unwrap();
        match run.declared {
            Some((harnesses, method)) => {
                let table: toml::Table = written.parse().unwrap();
                let tidy = table.get("skills").and_then(|skills| skills.get("tidy"));
                assert_eq!(
                    tidy.and_then(|tidy| tidy.get("harnesses")),
                    Some(&toml::Value::from(harnesses.to_vec())),
                    "{what}:\n{written}\n{text}"
                );
                assert_eq!(
                    tidy.and_then(|tidy| tidy.get("method"))
                        .and_then(toml::Value::as_str),
                    Some(method),
                    "{what}:\n{written}\n{text}"
                );
                let landed = fs::symlink_metadata(project.join(".claude/skills/tidy")).unwrap();
                assert!(landed.is_dir(), "{what}: not a copy:\n{text}");
            }
            None => {
                assert_eq!(written, manifest, "{what}: the manifest was written");
                assert!(
                    !project.join(".agents").exists() && !project.join(".claude").exists(),
                    "{what}: files were written:\n{text}"
                );
            }
        }
    }
}
