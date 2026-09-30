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
fn the_current_catalog_renders_and_an_undeliverable_hook_fails_verification() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let repository = repo();
    let script = repository.join("tools/catalog-release-check");
    let output = check(&script, &repository, &root);
    assert!(output.status.success(), "{output:?}");
    let record = String::from_utf8(output.stdout).unwrap();
    assert!(record.starts_with("catalog-release: version="), "{record}");
    assert!(record.contains(" result=pass"), "{record}");

    // A catalog author can name an event a declared harness never fires.
    // add accepts the partial plan; the consumer's verify must still fail.
    let catalog = root.join("future-catalog");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(catalog.join("hooks/future.sh"),
        "#!/bin/sh\n# ---\n# name: future\n# event: BeforeAgent\n# description: A Gemini event Claude never fires\n# harnesses: [claude]\n# ---\nexit 0\n").unwrap();
    let output = check(&script, &catalog, &root);
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    let record = String::from_utf8(output.stdout).unwrap();
    assert!(record.starts_with("catalog-release: version="), "{record}");
    assert!(
        record.lines().next().unwrap().contains("feature="),
        "{record}"
    );
    assert!(
        record
            .lines()
            .next()
            .unwrap()
            .contains("kendex-hook-undeliverable: hook=future harness=claude"),
        "{record}"
    );
    assert!(
        record
            .lines()
            .next()
            .unwrap()
            .contains("not in the install record"),
        "{record}"
    );
    assert_eq!(
        fs::read_to_string(catalog.join("kendex.toml")).unwrap(),
        "is_source_catalog = true\n",
        "the checker must not change its input"
    );

    // Make the exit-status rule inert without deleting its command or
    // diagnostic. The same fixture then passes, which the row above rejects.
    let text = fs::read_to_string(&script).unwrap();
    let target = "if rendered.returncode != 0:";
    assert_eq!(text.matches(target).count(), 1);
    let mutated = text.replace(target, "if False and rendered.returncode != 0:");
    assert_ne!(text, mutated);
    let mutant = root.join("inert-render-check.py");
    fs::write(&mutant, mutated).unwrap();
    let output = check(&mutant, &catalog, &root);
    assert!(
        output.status.success(),
        "control must reach the incorrect pass: {output:?}"
    );
    assert!(
        String::from_utf8(output.stdout)
            .unwrap()
            .contains(" result=pass")
    );
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
    let render = run_script(&step(
        &text,
        "name: Render the catalog with the released engine",
    ));
    assert_eq!(
        render.trim(),
        "python3 kendex/tools/catalog-release-check \"$HOME/.local/bin/kendex\" \"$CATALOG_PATH\""
    );
    assert!(!text.contains("cargo build"));
    assert!(!text.contains("target/release/kendex"));
}
