//! Catalog CI must render with the binary it installed, not its checkout's
//! authoring rules. Install the same latest release as the workflow, then run
//! its checker against that binary. A checkout build is not release evidence.
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
fn check(binary: &Path, script: &Path, catalog: &Path, root: &Path) -> Output {
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
    let repository = repo();
    let script = repository.join("tools/catalog-release-check");
    let home = root.join("release-home");
    fs::create_dir(&home).unwrap();
    let install = Command::new("/bin/bash")
        .arg(repository.join("skills/review-gate/scripts/install-latest.sh"))
        .current_dir(&root)
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap())
        .env("HOME", &home)
        .env("KENDEX_REAL_HOME", "1")
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("XDG_DATA_HOME", home.join(".local/share"))
        .env("XDG_CACHE_HOME", home.join(".cache"))
        .output()
        .unwrap();
    assert!(install.status.success(), "release install: {install:?}");
    eprintln!("{}", String::from_utf8_lossy(&install.stdout));
    let binary = home.join(".local/bin/kendex");
    let output = check(&binary, &script, &repository, &root);
    eprintln!(
        "current catalog: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    assert!(output.status.success(), "{output:?}");
    let record = String::from_utf8(output.stdout).unwrap();
    assert!(record.starts_with("catalog-release: version="), "{record}");
    assert!(record.contains(" result=pass"), "{record}");

    let text = fs::read_to_string(&script).unwrap();
    // Both declarations parse. Core's catalog check must refuse delivery
    // to the named unsupported harness before the wrapper installs anything.
    let manifest = "is_source_catalog = true\n";
    for (name, event, harnesses, expected_feature, control) in [
        (
            "permission-request",
            "PermissionRequest",
            "claude, gemini",
            "kendex-hook-unsupported: harness=gemini event=PermissionRequest hook=future",
            Some((
                "if rendered.returncode != 0:",
                "if False and rendered.returncode != 0:",
            )),
        ),
        (
            "subagent-stop",
            "SubagentStop",
            "claude, codex",
            "kendex-hook-unsupported: harness=codex event=SubagentStop hook=future",
            None,
        ),
    ] {
        let catalog = root.join(name);
        fs::create_dir_all(catalog.join("hooks")).unwrap();
        fs::write(catalog.join("kendex.toml"), manifest).unwrap();
        fs::write(catalog.join("hooks/future.sh"), format!(
            "#!/bin/sh\n# ---\n# name: future\n# event: {event}\n# description: Check requests\n# harnesses: [{harnesses}]\n# ---\nexit 0\n")).unwrap();
        let rejects = |output: &Output| {
            let record = String::from_utf8_lossy(&output.stdout);
            output.status.code() == Some(1)
                && record.starts_with("catalog-release: version=")
                && record.lines().next().unwrap().contains("feature=")
                && record.lines().next().unwrap().contains(expected_feature)
        };
        let output = check(&binary, &script, &catalog, &root);
        eprintln!("{name}: {}", String::from_utf8_lossy(&output.stdout));
        assert!(rejects(&output), "{name}: {output:?}");
        assert_eq!(
            fs::read_to_string(catalog.join("kendex.toml")).unwrap(),
            manifest,
            "the checker must not change its input"
        );

        if let Some((target, replacement)) = control {
            // Keep the commands and diagnostic, but disable the refusal.
            // The same rejection assertion must then fail.
            assert_eq!(text.matches(target).count(), 1);
            let mutated = text.replace(target, replacement);
            assert_ne!(text, mutated);
            let mutant = root.join(format!("inert-{name}.py"));
            fs::write(&mutant, mutated).unwrap();
            let output = check(&binary, &mutant, &catalog, &root);
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
            "python3 kendex/tools/catalog-release-check \"$HOME/.local/bin/kendex\" \"$CATALOG_PATH\" ${{ !inputs.strict && '--allow-advisories' || '' }}"
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
