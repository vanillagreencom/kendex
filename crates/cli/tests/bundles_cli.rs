//! Installing and uninstalling a curated set from the command line: one flag
//! declares the set, and taking it away says which members go, which stay,
//! and what accounts for each. A declared set its catalog renamed fails a
//! refresh and keeps its members; one the catalog retired keeps them until
//! a prune.
#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn write(root: &Path, rel: &str, text: &str) {
    let path = root.join(rel);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A catalog offering one set of two skills and an agent.
#[allow(clippy::unwrap_used)]
fn catalog(home: &Path) -> std::path::PathBuf {
    let catalog = home.join("catalog");
    for name in ["alpha", "beta"] {
        write(
            &catalog,
            &format!("skills/{name}/SKILL.md"),
            &format!("---\nname: {name}\ndescription: the {name} skill\n---\nBody.\n"),
        );
    }
    write(
        &catalog,
        "agents/writer.md",
        "---\nname: writer\ndescription: writes things\n---\n\nWrite.\n",
    );
    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"alpha\", \"beta\"]\nagents = [\"writer\"]\n",
    );
    catalog
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_installs_whole_and_uninstalls_with_the_split_said_out_loud() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    fs::create_dir_all(home.join(".claude/skills")).unwrap();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = catalog(home);

    // One flag declares the set, and `beta` is also asked for by name.
    let output = kendex(
        home,
        &project,
        &[
            "add",
            catalog.to_str().unwrap(),
            "--bundle",
            "starter",
            "--skill",
            "beta",
            "--harness",
            "claude",
            "-y",
        ],
    );
    assert!(
        output.status.success(),
        "add failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(project.join(".claude/skills/alpha").exists());
    assert!(project.join(".claude/skills/beta").exists());
    assert!(project.join(".claude/agents/writer.md").exists());

    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[bundles.starter]"), "{manifest}");
    assert!(!manifest.contains("[skills.alpha]"), "{manifest}");
    assert!(manifest.contains("[skills.beta]"), "{manifest}");

    // Taking the set away says what goes and what stays, with the reason.
    let output = kendex(home, &project, &["remove", "starter"]);
    assert!(
        output.status.success(),
        "remove failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(
        said.contains("removing skill alpha") && said.contains("part of the starter bundle"),
        "{said}"
    );
    assert!(said.contains("removing agent writer"), "{said}");
    assert!(
        said.contains("keeping skill beta") && said.contains("asked for"),
        "{said}"
    );

    assert!(!project.join(".claude/skills/alpha").exists());
    assert!(!project.join(".claude/agents/writer.md").exists());
    assert!(
        project.join(".claude/skills/beta").exists(),
        "a member the user asked for went with the set"
    );
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(!manifest.contains("[bundles.starter]"), "{manifest}");
}

/// A name no catalog offers a set under is an error that changes nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_the_catalog_lacks_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = catalog(home);

    let output = kendex(
        home,
        &project,
        &[
            "add",
            catalog.to_str().unwrap(),
            "--bundle",
            "nonesuch",
            "--harness",
            "claude",
            "-y",
        ],
    );
    assert!(!output.status.success());
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(said.contains("no bundle called 'nonesuch'"), "{said}");
    assert!(!project.join("kendex.toml").exists());
}

/// Jarvis's native identity carrier calls the judge beside it. The shipped
/// bundle must install both, as well as the runtime and its required skills.
#[test]
#[allow(clippy::unwrap_used)]
fn the_jarvis_bundle_installs_the_carrier_beside_its_judge() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/jarvis");
    fs::create_dir_all(&project).unwrap();
    // The override belongs to the test boundary: the must-fail control
    // removes the hook group from a disposable copy of this real catalog.
    let catalog = std::env::var_os("JARVIS_TEST_CATALOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."))
        .canonicalize()
        .unwrap();
    let output = kendex(
        &home,
        &project,
        &[
            "add",
            catalog.to_str().unwrap(),
            "--bundle",
            "jarvis",
            "--harness",
            "claude,codex,copilot,pi",
            "--yes",
            "--throwaway",
        ],
    );
    assert!(output.status.success(), "{}", printed(&output));
    if let Some(ready) = std::env::var_os("JARVIS_TEST_INSTALL_READY") {
        fs::write(ready, "installed\n").unwrap();
    }
    assert!(
        project
            .join(".agents/skills/jarvis/scripts/jarvis-session")
            .is_file()
    );
    assert!(
        project
            .join(".agents/skills/orch/scripts/lib/session-rows.sh")
            .is_file()
    );
    let lock = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
    let carriers: Vec<_> = lock
        .entries
        .values()
        .filter(|entry| {
            entry.kind == kendex_core::model::ItemKind::Hook && entry.name == "session-start-row"
        })
        .collect();
    assert!(!carriers.is_empty(), "Jarvis carrier is absent");
    for carrier in carriers {
        let paths = &carrier.emitted.as_ref().unwrap().paths;
        assert!(!paths.is_empty());
        for path in paths {
            let path = project.join(path);
            assert!(path.is_file(), "carrier is not installed");
            assert!(path.parent().unwrap().join("lane-mail-check.sh").is_file());
        }
    }
    if std::env::var_os("JARVIS_TEST_CATALOG").is_none() {
        assert_jarvis_hook_group_control(&catalog, &home);
    }
}

/// The control removes the bundle hooks and reruns the actual install row.
#[allow(clippy::unwrap_used)]
fn assert_jarvis_hook_group_control(catalog: &Path, home: &Path) {
    let mutant = home.join("mutant-catalog");
    for directory in ["skills", "agents", "hooks"] {
        crate::install_ux::guarding::copy_tree(&catalog.join(directory), &mutant.join(directory));
    }
    let mut document: toml::Table = fs::read_to_string(catalog.join("kendex.toml"))
        .unwrap()
        .parse()
        .unwrap();
    let hooks = document["bundles"]["jarvis"]["hooks"]
        .as_array_mut()
        .unwrap();
    assert!(
        hooks
            .iter()
            .any(|hook| hook.as_str() == Some("session-start-row"))
    );
    // Each hook requires the other, so either member installs the pair.
    // Remove the bundle's hook group to reach an absent carrier.
    hooks.clear();
    fs::write(
        mutant.join("kendex.toml"),
        toml::to_string(&document).unwrap(),
    )
    .unwrap();
    let ready = home.join("control-install-ready");
    let child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "bundles_cli::the_jarvis_bundle_installs_the_carrier_beside_its_judge",
            "--nocapture",
        ])
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("JARVIS_TEST_CATALOG", &mutant)
        .env("JARVIS_TEST_INSTALL_READY", &ready)
        .output()
        .unwrap();
    assert!(
        ready.is_file(),
        "control install did not reach the bundle check"
    );
    assert!(
        !child.status.success(),
        "the missing carrier control passed"
    );
}

/// The catalog renames the set a consumer declared: refresh fails, its
/// members stay installed, and verify fails the set. Retiring it instead
/// lets a plain refresh and verify pass with one notice keyed by the set
/// and its members kept, and a prune drops the declaration and takes them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_bundle_gone_from_its_catalog_fails_refresh_unless_retired() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = catalog(&home);
    let added = kendex(
        &home,
        &project,
        &[
            "add",
            catalog.to_str().unwrap(),
            "--bundle",
            "starter",
            "--harness",
            "claude",
            "-y",
        ],
    );
    assert!(added.status.success(), "{}", printed(&added));
    let members = [".claude/skills/alpha", ".claude/agents/writer.md"].map(|m| project.join(m));
    let refresh = |extra: &[&str]| {
        let args = [
            &["refresh", "--scope", "project", "--yes", "--leave"][..],
            extra,
        ]
        .concat();
        kendex(&home, &project, &args)
    };
    let declared = || {
        let manifest: toml::Table = fs::read_to_string(project.join("kendex.toml"))
            .unwrap()
            .parse()
            .unwrap();
        manifest
            .get("bundles")
            .and_then(|bundles| bundles.get("starter"))
            .is_some()
    };

    let set = "description = \"the starter set\"\nskills = [\"alpha\", \"beta\"]\nagents = [\"writer\"]\n";
    write(&catalog, "kendex.toml", &format!("[bundles.begin]\n{set}"));
    let renamed = refresh(&[]);
    let said = printed(&renamed);
    assert!(!renamed.status.success(), "{said}");
    for member in &members {
        assert!(member.exists(), "{} is gone: {said}", member.display());
    }
    assert!(declared(), "{said}");
    let verify = || kendex(&home, &project, &["verify", "--scope", "project", "--json"]);
    let verified = verify();
    let said = printed(&verified);
    assert!(!verified.status.success(), "{said}");
    let document: kendex_core::attest::Document = serde_json::from_slice(&verified.stdout).unwrap();
    let failed: Vec<(&str, &str, Option<&str>)> = document
        .rows
        .iter()
        .filter(|row| row.state == kendex_core::attest::State::Failed)
        .map(|row| (row.kind.as_str(), row.name.as_str(), row.detail.as_deref()))
        .collect();
    assert!(
        matches!(failed[..], [("bundle", "starter", Some(detail))] if detail.contains("begin")),
        "{said}"
    );

    write(
        &catalog,
        "kendex.toml",
        &format!("[bundles.begin]\n{set}[retired.bundles]\nstarter = \"declare begin\"\n"),
    );
    let kept = refresh(&[]);
    let said = printed(&kept);
    assert!(kept.status.success(), "{said}");
    let keyed = said
        .lines()
        .filter(|line| line.contains("bundle starter: "))
        .count();
    assert_eq!(keyed, 1, "{said}");
    for member in &members {
        assert!(member.exists(), "{} is gone: {said}", member.display());
    }
    let verified = verify();
    assert!(verified.status.success(), "{}", printed(&verified));

    let pruned = refresh(&["--prune"]);
    let said = printed(&pruned);
    assert!(pruned.status.success(), "{said}");
    for member in &members {
        assert!(!member.exists(), "{} stays: {said}", member.display());
    }
    assert!(!declared(), "{said}");
}

fn printed(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}
