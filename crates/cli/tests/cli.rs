#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

// Integration-test helpers sit outside #[test] fns, so clippy's
// allow-unwrap-in-tests does not reach them.
#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn fixture_home() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    fs::create_dir_all(home.join(".claude/agents")).unwrap();
    fs::write(
        home.join(".claude/agents/orch.md"),
        "---\ndescription: boss\n---\n",
    )
    .unwrap();
    fs::create_dir_all(home.join("dev/app/.claude/skills/deploy")).unwrap();
    fs::write(home.join("dev/app/.claude/skills/deploy/SKILL.md"), "# d").unwrap();
    tmp
}

#[test]
fn list_sees_global_and_current_project_scopes() {
    let tmp = fixture_home();
    let home = tmp.path();

    let output = kendex(home, &home.join("dev/app"), &["list"]);
    assert!(output.status.success());
    let table = String::from_utf8_lossy(&output.stderr);
    assert!(table.contains("orch"), "global agent missing: {table}");
    assert!(table.contains("deploy"), "project skill missing: {table}");

    let output = kendex(home, &home.join("dev/app"), &["ls", "--scope", "project"]);
    let table = String::from_utf8_lossy(&output.stderr);
    assert!(!table.contains("orch"));
    assert!(table.contains("deploy"));

    let output = kendex(
        home,
        &home.join("dev/app"),
        &["list", "-g", "--harness", "claude-code"],
    );
    let table = String::from_utf8_lossy(&output.stderr);
    assert!(table.contains("orch"));
    assert!(!table.contains("deploy"));
}

#[test]
fn scope_project_outside_a_project_is_an_error() {
    let tmp = fixture_home();
    let home = tmp.path();
    let output = kendex(home, home, &["list", "--scope", "project"]);
    assert!(!output.status.success());
}

#[test]
fn check_is_clean_and_quiet_on_a_scope_with_no_drift() {
    let tmp = fixture_home();
    let home = tmp.path();
    let output = kendex(home, &home.join("dev/app"), &["check"]);
    assert!(output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("all clear"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );

    // The hook's mode: silence when clean, on both streams.
    let quiet = kendex(home, &home.join("dev/app"), &["check", "--quiet"]);
    assert!(quiet.status.success());
    assert_eq!(String::from_utf8_lossy(&quiet.stdout).trim(), "");
    assert_eq!(String::from_utf8_lossy(&quiet.stderr).trim(), "");

    let json = kendex(home, &home.join("dev/app"), &["check", "--json"]);
    assert!(json.status.success());
    let parsed: serde_json::Value =
        serde_json::from_slice(&json.stdout).expect("check --json is valid JSON");
    assert_eq!(parsed["status"], "clean");
}

#[test]
fn project_registry_round_trips() {
    let tmp = fixture_home();
    let home = tmp.path();

    let add = kendex(home, home, &["project", "add", "dev/app"]);
    assert!(add.status.success());

    let list = kendex(home, home, &["project", "list"]);
    assert!(String::from_utf8_lossy(&list.stdout).contains("dev/app"));

    let discover = kendex(home, home, &["project", "discover", "dev"]);
    assert!(String::from_utf8_lossy(&discover.stdout).contains("dev/app"));

    let remove = kendex(home, home, &["project", "remove", "dev/app"]);
    assert!(remove.status.success());
    let list = kendex(home, home, &["project", "list"]);
    assert_eq!(String::from_utf8_lossy(&list.stdout).trim(), "");
}

/// A hook can be installed exactly as declared and still do nothing. The one
/// command built for pipelines has to say so rather than tick it green.
#[test]
#[allow(clippy::unwrap_used)]
fn verify_names_an_installation_that_cannot_act() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".github")).unwrap();
    // Walking up from the cwd settles on a directory carrying a harness
    // folder, which is what makes this a project the CLI will act on.
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(home.join(".copilot")).unwrap();
    fs::write(
        home.join(".copilot/settings.json"),
        "{\"disableAllHooks\": true}",
    )
    .unwrap();

    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    // Hooks install only from a catalog that declares kendex's layout.
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("hooks/audit.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: audit\n# event: PreToolUse\n# matcher: Bash\n# description: log shell commands\n# ---\nexit 0\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"copilot\"]\nmethod = \"copy\"\n\n[hooks.audit]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();

    assert!(kendex(home, &project, &["apply", "-y"]).status.success());
    let output = kendex(home, &project, &["verify"]);
    assert!(output.status.success());
    let printed = String::from_utf8_lossy(&output.stderr);
    assert!(printed.contains("✓ hook audit [copilot]"), "{printed}");
    assert!(
        printed.contains("!") && printed.contains("stays inert"),
        "{printed}"
    );
}

/// The real binary — not just the library — runs the global-dir move
/// before its verb: state under the old `vstack2` config dir lands under
/// `kendex` on any command at all.
#[test]
#[allow(clippy::unwrap_used)]
fn any_verb_moves_the_global_dirs_off_vstack2() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    // The platform config root the binary itself resolves: macOS reads
    // Library/Application Support and ignores XDG variables entirely.
    #[cfg(target_os = "macos")]
    let config = home.join("Library/Application Support");
    #[cfg(not(target_os = "macos"))]
    let config = home.join(".config");
    fs::create_dir_all(config.join("vstack2")).unwrap();
    let settings = format!("schema = 1\nprojects = [\"{}/dev/app\"]\n", home.display());
    fs::write(config.join("vstack2/settings.toml"), &settings).unwrap();

    let output = kendex(home, home, &["project", "list"]);
    assert!(output.status.success(), "{output:?}");
    // The registered project prints, proving the verb read the moved file.
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("dev/app"),
        "{output:?}"
    );
    assert_eq!(
        fs::read_to_string(config.join("kendex/settings.toml")).unwrap(),
        settings
    );
    assert!(!config.join("vstack2").exists());
}

/// The rename ships a `vstack` alias binary for one release cycle:
/// consuming repos' git-hook entrypoints hard-code `vstack guard run` and
/// fail closed while the alias is missing.
#[test]
fn vstack_alias_binary_answers() {
    let tmp = tempfile::tempdir().unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_vstack"))
        .arg("--version")
        .env_clear()
        .env("HOME", tmp.path())
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("kendex"));
}
