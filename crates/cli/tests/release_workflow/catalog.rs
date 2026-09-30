//! Catalog CI must render with the binary it installed, not its checkout's
//! authoring rules. Run the workflow's checker against the real CLI.
#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

use super::{run_script, step};
use crate::test_util::{checkout_root, rooted};

#[allow(clippy::unwrap_used)]
fn check(script: &Path, catalog: &Path, root: &Path) -> Output {
    let binary = std::env::var_os("KENDEX_CATALOG_TEST_BINARY")
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_kendex").into());
    Command::new("python3")
        .arg(script)
        .arg(binary)
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
    let repository = checkout_root();
    let script = repository.join("tools/catalog-release-check");
    let output = check(&script, &repository, &root);
    assert!(output.status.success(), "{output:?}");
    let record = String::from_utf8(output.stdout).unwrap();
    assert!(record.contains(" result=pass"), "{record}");

    let text = fs::read_to_string(&script).unwrap();
    // Engine delivery failures can leave another harness installed. A
    // Claude-only header excludes Gemini intentionally; advisory delivery
    // also passes. The manifest parser fails without a delivery diagnostic.
    let unsupported = "kendex-hook-unsupported";
    let undeliverable = "kendex-hook-undeliverable";
    for (n, (event, harnesses, feature)) in [
        (Some("BeforeAgent"), "claude, gemini", undeliverable),
        (Some("PermissionRequest"), "claude, gemini", unsupported),
        (Some("PermissionRequest"), "claude, pi", unsupported),
        (Some("SubagentStop"), "claude, codex", unsupported),
        (Some("TaskCompleted"), "claude, copilot", unsupported),
        (Some("SessionStart"), "claude, antigravity", unsupported),
        (Some(""), "claude, gemini", "kendex-hook-unreadable"),
        (Some("PreToolUse"), "claude", ""),
        (Some("PreToolUse"), "opencode, cursor, pi", ""),
        (None, "claude", "is_source_catalog"),
    ]
    .into_iter()
    .enumerate()
    {
        let catalog = root.join(n.to_string());
        fs::create_dir_all(catalog.join("hooks")).unwrap();
        let manifest = match event {
            Some(_) => "is_source_catalog = true\n",
            None => "is_source_catalog = []\n",
        };
        fs::write(catalog.join("kendex.toml"), manifest).unwrap();
        let hook_event = event.unwrap_or("PreToolUse");
        for name in ["future", "other"] {
            fs::write(catalog.join(format!("hooks/{name}.sh")), format!(
                "#!/bin/sh\n# ---\n# name: {name}\n# event: {hook_event}\n# description: Hook delivery fixture\n# harnesses: [{harnesses}]\n# ---\nexit 0\n")).unwrap();
        }
        let accepts = |output: &Output| {
            let record = String::from_utf8_lossy(&output.stdout);
            record.starts_with("catalog-release: version=")
                && match feature {
                    "" => output.status.success() && record.contains(" result=pass"),
                    key => {
                        output.status.code() == Some(1)
                            && record.lines().next().unwrap().contains("feature=")
                            && record.lines().next().unwrap().contains(key)
                    }
                }
        };
        let output = check(&script, &catalog, &root);
        assert!(accepts(&output), "{event:?} [{harnesses}]: {output:?}");
        assert_eq!(
            fs::read_to_string(catalog.join("kendex.toml")).unwrap(),
            manifest
        );

        let target = match event {
            Some("BeforeAgent") => "refusal.search(diagnostic)",
            None => "rendered.returncode != 0",
            Some(_) => continue,
        };
        // Disable each independent rule without changing commands or text.
        // The same row assertion must reject the resulting incorrect pass.
        assert_eq!(text.matches(target).count(), 1);
        let mutated = text.replace(target, &format!("(False and {target})"));
        assert_ne!(text, mutated);
        let mutant = root.join(format!("inert-{n}.py"));
        fs::write(&mutant, mutated).unwrap();
        let output = check(&mutant, &catalog, &root);
        assert!(
            output.status.success(),
            "control must reach the incorrect pass: {output:?}"
        );
        assert!(String::from_utf8_lossy(&output.stdout).contains(" result=pass"));
        assert!(
            !accepts(&output),
            "control escaped the row assertion: {output:?}"
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn catalog_ci_installs_the_release_and_runs_its_render_check() {
    let text =
        fs::read_to_string(checkout_root().join(".github/workflows/catalog-check.yml")).unwrap();
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
