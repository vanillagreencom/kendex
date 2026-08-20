//! The add surface covers every installable kind, spelled the way §4.2
//! says: per-kind flags for hooks, commands and MCP servers, bare names
//! found by search, and Pi extensions refused toward their carrier.
#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

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
fn write(root: &Path, rel: &str, text: &str) {
    let path = root.join(rel);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn project_with_catalog(home: &Path) -> std::path::PathBuf {
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = home.join("catalog");
    write(
        &catalog,
        "hooks/guard.sh",
        "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: block dangerous commands\n# ---\nexit 0\n",
    );
    write(&catalog, "commands/ship.md", "Ship the branch.\n");
    // Executable kinds are only offered by a catalog that declared
    // kendex's layout; an undeclared hooks/ folder is repository tooling.
    write(&catalog, "kendex.toml", "[catalog]\n");
    write(
        &catalog,
        "mcp/gh.toml",
        "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n",
    );
    write(
        &project,
        "kendex.toml",
        &format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            catalog.display()
        ),
    );
    project
}

/// One command, three kind flags, bare names resolved by the search — the
/// flags exist and the declarations land.
#[test]
#[allow(clippy::unwrap_used)]
fn hook_command_and_mcp_server_flags_declare_and_install() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with_catalog(home);

    let output = kendex(
        home,
        &project,
        &[
            "add",
            "--hook",
            "guard",
            "--command",
            "ship",
            "--mcp-server",
            "gh",
            "-y",
        ],
    );
    assert!(
        output.status.success(),
        "add failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(project.join(".claude/hooks/guard.sh").is_file());
    assert!(project.join(".claude/commands/ship.md").exists());
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    for declared in ["[hooks.guard]", "[commands.ship]", "[mcp-servers.gh]"] {
        assert!(
            manifest.contains(declared),
            "{declared} missing: {manifest}"
        );
    }
}

/// `--pi-extension` reaches the engine and comes back with the carrier
/// explanation, not a phase excuse.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pi_extension_flag_is_refused_toward_its_carrier_bundle() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with_catalog(home);

    let output = kendex(home, &project, &["add", "--pi-extension", "pi-hooks", "-y"]);
    assert!(!output.status.success());
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(said.contains("not installable on its own"), "{said}");
}

/// The same carrier explanation reaches a global add: `--pi-extension` is
/// an explicit selection, so the gate lets the engine explain instead of
/// demanding selections that were already given.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_pi_extension_flag_gets_the_carrier_explanation() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with_catalog(home);

    let output = kendex(
        home,
        &project,
        &["add", "--global", "--pi-extension", "pi-hooks", "-y"],
    );
    assert!(!output.status.success());
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(said.contains("not installable on its own"), "{said}");
}
