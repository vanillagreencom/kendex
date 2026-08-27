//! Black-box tests for the binding surface: bare-form add, report routing
//! (dry-run + stubbed gh), self-update against a local release feed, and
//! init scaffolding.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex_in(home: &Path, cwd: &Path, args: &[&str], envs: &[(&str, String)]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default());
    for (key, value) in envs {
        command.env(key, value);
    }
    command.output().expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn sandbox_with_catalog() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    fs::create_dir_all(home.join("catalog/skills/gh")).unwrap();
    fs::write(
        home.join("catalog/skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github\n---\nBody.\n",
    )
    .unwrap();
    fs::create_dir_all(home.join("proj/.claude")).unwrap();
    tmp
}

#[test]
fn bare_form_maps_to_add_flag_for_flag() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let catalog = home.join("catalog").display().to_string();

    let output = kendex_in(
        home,
        &home.join("proj"),
        &[&catalog, "--skill", "gh", "--harness", "claude", "-y"],
        &[],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(home.join("proj/.agents/skills/gh/SKILL.md").is_file());
    assert!(home.join("proj/.claude/skills/gh").is_symlink());
}

#[test]
fn report_dry_run_routes_by_ownership_and_rejects_scope_all() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let proj = home.join("proj");
    // A locked agent from the canonical upstream routes to it — the
    // pre-move repo spelling in the entry included, since installed content
    // predating the repository move still records it.
    fs::write(
        proj.join(".vstack-lock.json"),
        r#"{"version":1,"entries":{"agent:orch:claude":{"name":"orch","kind":"agent","harness":"claude","source":"vstack","sourceRepo":"vanillagreencom/vstack","method":"copy","installedAt":"2026-01-01T00:00:00Z","sourceHash":"x","enabled":true}}}"#,
    )
    .unwrap();

    let upstream = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--agent",
            "orch",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    assert!(upstream.status.success());
    let text = String::from_utf8_lossy(&upstream.stderr);
    assert!(text.contains("ownership: kendex"), "{text}");
    assert!(text.contains("--repo vanillagreencom/kendex"), "{text}");
    assert!(text.contains("--label skills"), "{text}");

    let local = kendex_in(
        home,
        &proj,
        &[
            "report",
            "--asset",
            "mystery",
            "--title",
            "T",
            "--body",
            "B",
            "--dry-run",
        ],
        &[],
    );
    let text = String::from_utf8_lossy(&local.stderr);
    assert!(text.contains("ownership: project-local"), "{text}");
    assert!(!text.contains("--label"), "{text}");

    let rejected = kendex_in(
        home,
        &proj,
        &["report", "--title", "T", "--body", "B", "--scope", "all"],
        &[],
    );
    assert!(!rejected.status.success());
}

#[test]
#[allow(clippy::unwrap_used)]
fn report_files_through_a_stubbed_gh() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let proj = home.join("proj");
    fs::write(
        proj.join(".vstack-lock.json"),
        r#"{"version":1,"entries":{"hook:guard:claude":{"name":"guard","kind":"hook","harness":"claude","source":"vstack","sourceRepo":"vanillagreencom/vstack","method":"copy","installedAt":"2026-01-01T00:00:00Z","sourceHash":"x","enabled":true}}}"#,
    )
    .unwrap();

    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let gh = bin.join("gh");
    fs::write(
        &gh,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > {}/gh-args.txt\necho https://github.com/x/1\n",
            home.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );

    let output = kendex_in(
        home,
        &proj,
        &[
            "report", "--hook", "guard", "--title", "Broken", "--body", "Details",
        ],
        &[("PATH", path)],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("Issue filed: https://github.com/x/1")
    );
    let args = fs::read_to_string(home.join("gh-args.txt")).unwrap();
    assert!(args.contains("vanillagreencom/kendex"));
    assert!(args.contains("harness"));
    assert!(args.contains("kendex-report:v1 asset=guard kind=hook"));
}

#[test]
#[allow(clippy::unwrap_used)]
fn update_replaces_the_binary_from_a_local_feed() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let me = bin.join("vstack");
    fs::copy(env!("CARGO_BIN_EXE_kendex"), &me).unwrap();
    fs::set_permissions(&me, fs::Permissions::from_mode(0o755)).unwrap();

    fs::write(home.join("new-binary"), "#!/bin/sh\necho v9\n").unwrap();
    let target = env!("KENDEX_TARGET");
    fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"schema": 1, "version": "9.9.9", "assets": {{"{target}": "file://{}/new-binary"}}}}"#,
            home.display()
        ),
    )
    .unwrap();

    let output = Command::new(&me)
        .args(["update"])
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env(
            "KENDEX_UPDATE_FEED",
            format!("file://{}/feed.json", home.display()),
        )
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(fs::read_to_string(&me).unwrap(), "#!/bin/sh\necho v9\n");

    // Same version → no-op without --force.
    let same = fs::read_to_string(home.join("feed.json"))
        .unwrap()
        .replace("9.9.9", env!("CARGO_PKG_VERSION"));
    fs::write(home.join("feed.json"), same).unwrap();
    let output = kendex_in(
        home,
        home,
        &["update"],
        &[(
            "KENDEX_UPDATE_FEED",
            format!("file://{}/feed.json", home.display()),
        )],
    );
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("already up to date"));

    let older = fs::read_to_string(home.join("feed.json"))
        .unwrap()
        .replace(env!("CARGO_PKG_VERSION"), "0.1.0");
    fs::write(home.join("feed.json"), older).unwrap();
    let output = kendex_in(
        home,
        home,
        &["update"],
        &[(
            "KENDEX_UPDATE_FEED",
            format!("file://{}/feed.json", home.display()),
        )],
    );
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("older than installed"));

    fs::write(
        home.join("feed.json"),
        r#"{"schema":1,"version":"99.0.0","assets":{}}"#,
    )
    .unwrap();
    let output = kendex_in(
        home,
        home,
        &["update"],
        &[(
            "KENDEX_UPDATE_FEED",
            format!("file://{}/feed.json", home.display()),
        )],
    );
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("releases/tag/v99.0.0"));

    fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"version":"{}","assets":{{}}}}"#,
            env!("CARGO_PKG_VERSION")
        ),
    )
    .unwrap();
    let output = kendex_in(
        home,
        home,
        &["update", "--force"],
        &[(
            "KENDEX_UPDATE_FEED",
            format!("file://{}/feed.json", home.display()),
        )],
    );
    let current = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert!(current.contains("unchanged") && !current.contains("is available"));

    fs::write(
        home.join("feed.json"),
        r#"{"schema":1,"version":"0.1.0","assets":{}}"#,
    )
    .unwrap();
    let output = kendex_in(
        home,
        home,
        &["update", "--force"],
        &[(
            "KENDEX_UPDATE_FEED",
            format!("file://{}/feed.json", home.display()),
        )],
    );
    let older = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert!(older.contains("is newer") && !older.contains("is available"));
}

#[test]
#[allow(clippy::unwrap_used)]
fn update_refuses_an_asset_value_that_is_not_a_url() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let target = env!("KENDEX_TARGET");
    fs::write(
        home.join("feed.json"),
        format!(
            r#"{{"schema":1,"version":"99.0.0","assets":{{"{target}":"--output={}/owned"}}}}"#,
            home.display()
        ),
    )
    .unwrap();

    let output = kendex_in(
        home,
        home,
        &["update"],
        &[(
            "KENDEX_UPDATE_FEED",
            format!("file://{}/feed.json", home.display()),
        )],
    );
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("URL must start"));
    assert!(!home.join("owned").exists());
}

#[test]
fn init_scaffolds_and_validates() {
    let tmp = sandbox_with_catalog();
    let home = tmp.path();
    let output = kendex_in(
        home,
        &home.join("catalog"),
        &["init", "deploy", "--kind", "skill"],
        &[],
    );
    assert!(output.status.success());
    let skill_md = std::fs::read_to_string(home.join("catalog/skills/deploy/SKILL.md")).unwrap();
    assert!(
        skill_md.contains("commands to run, rules to follow"),
        "scaffold body lost the do-only directive: {skill_md}"
    );

    let usage = kendex_in(home, &home.join("catalog"), &["init"], &[]);
    assert!(usage.status.success());

    let bad = kendex_in(
        home,
        &home.join("catalog"),
        &["init", "x", "--kind", "wat"],
        &[],
    );
    assert!(!bad.status.success());
}
