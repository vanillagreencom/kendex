//! Catalog CI must render with the binary it installed, not its checkout's
//! authoring rules. Run the workflow's checker against the real CLI.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use super::{run_script, step};
use crate::test_util::rooted;

#[allow(clippy::unwrap_used)]
fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap()
}

#[allow(clippy::unwrap_used)]
fn check(script: &Path, catalog: &Path, root: &Path) -> Output {
    Command::new("python3")
        .arg(script)
        .arg(env!("CARGO_BIN_EXE_kendex"))
        .arg(catalog)
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap())
        .env("RUNNER_TEMP", root)
        .output()
        .unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_current_catalog_renders_and_incomplete_delivery_fails() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let repository = repo();
    let script = repository.join("tools/catalog-release-check");
    let output = check(&script, &repository, &root);
    assert!(output.status.success(), "{output:?}");
    let record = String::from_utf8(output.stdout).unwrap();
    assert!(record.starts_with("catalog-release: version="), "{record}");
    assert!(record.contains(" result=pass"), "{record}");

    let text = fs::read_to_string(&script).unwrap();
    // desired_hook supplies the diagnostic. The mixed declaration installs
    // on Gemini, so every consumer command exits zero despite Claude's skip.
    // parse_hook refuses an empty event; verify then exits nonzero because
    // the hook is absent. This reaches the separate nonzero-command rule.
    let manifest = "is_source_catalog = true\n";
    for (name, event, harnesses, expected_feature, control) in [
        (
            "claude-only",
            "BeforeAgent",
            "claude",
            "kendex-hook-undeliverable: hook=future harness=claude",
            None,
        ),
        (
            "mixed-harness",
            "BeforeAgent",
            "claude, gemini",
            "kendex-hook-undeliverable: hook=future harness=claude",
            Some(("or undeliverable:", "or (False and undeliverable):")),
        ),
        (
            "empty-event",
            "",
            "claude, gemini",
            "kendex-hook-unreadable: hook=future",
            Some((
                "rendered.returncode != 0 or",
                "(False and rendered.returncode != 0) or",
            )),
        ),
    ] {
        let catalog = root.join(name);
        fs::create_dir_all(catalog.join("hooks")).unwrap();
        fs::write(catalog.join("kendex.toml"), manifest).unwrap();
        fs::write(catalog.join("hooks/future.sh"), format!(
            "#!/bin/sh\n# ---\n# name: future\n# event: {event}\n# description: A Gemini event Claude never fires\n# harnesses: [{harnesses}]\n# ---\nexit 0\n")).unwrap();
        let rejects = |output: &Output| {
            let record = String::from_utf8_lossy(&output.stdout);
            output.status.code() == Some(1)
                && record.starts_with("catalog-release: version=")
                && record.lines().next().unwrap().contains("feature=")
                && record.lines().next().unwrap().contains(expected_feature)
        };
        let output = check(&script, &catalog, &root);
        assert!(rejects(&output), "{name}: {output:?}");
        assert_eq!(
            fs::read_to_string(catalog.join("kendex.toml")).unwrap(),
            manifest,
            "the checker must not change its input"
        );

        if let Some((target, replacement)) = control {
            // Each control leaves the commands and diagnostic intact and
            // disables only its rule. The same rejection assertion must fail.
            assert_eq!(text.matches(target).count(), 1);
            let mutated = text.replace(target, replacement);
            assert_ne!(text, mutated);
            let mutant = root.join(format!("inert-{name}.py"));
            fs::write(&mutant, mutated).unwrap();
            let output = check(&mutant, &catalog, &root);
            assert!(
                output.status.success(),
                "control must reach the incorrect pass: {output:?}"
            );
            assert!(String::from_utf8_lossy(&output.stdout).contains(" result=pass"));
            assert!(
                !rejects(&output),
                "control escaped the rejection assertion: {output:?}"
            );
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn catalog_ci_installs_the_release_and_runs_its_render_check() {
    let text = fs::read_to_string(repo().join(".github/workflows/catalog-check.yml")).unwrap();
    let install = run_script(&step(&text, "name: Install latest released kendex"));
    assert_eq!(
        install.trim(),
        "kendex/skills/review-gate/scripts/install-latest.sh"
    );
    let assert_blocking_render = |workflow: &str| {
        let render_step = step(
            workflow,
            "name: Render the catalog with the released engine",
        );
        // GitHub defaults continue-on-error to false. With the checker as
        // the last shell command, a nonzero exit must fail this step.
        assert!(
            !render_step
                .iter()
                .any(|line| line.trim_start().starts_with("continue-on-error:")),
            "released-engine render must block catalog CI"
        );
        assert_eq!(
            run_script(&render_step).trim(),
            "python3 kendex/tools/catalog-release-check \"$HOME/.local/bin/kendex\" \"$CATALOG_PATH\""
        );
    };
    assert_blocking_render(&text);

    // Keep the command but suppress its blocking effect. The same assertion
    // must reject the workflow that GitHub would accept after a failed render.
    let target = "      - name: Render the catalog with the released engine\n";
    assert_eq!(text.matches(target).count(), 1);
    let mutated = text.replace(
        target,
        &format!("{target}        continue-on-error: true\n"),
    );
    assert_ne!(text, mutated);
    assert!(std::panic::catch_unwind(|| assert_blocking_render(&mutated)).is_err());
    assert!(!text.contains("cargo build"));
    assert!(!text.contains("target/release/kendex"));
}
