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
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        // Keeps the post-subscribe fetch off the network: shorthands
        // resolve under an empty local base and fail fast.
        .env(
            "KENDEX_GIT_BASE",
            format!("file://{}", home.join("base").display()),
        )
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn fixture_home() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let home = home.as_path();
    fs::create_dir_all(home.join("dev/app/.claude")).unwrap();
    fs::create_dir_all(home.join("catalog/skills/gh")).unwrap();
    fs::write(
        home.join("catalog/skills/gh/SKILL.md"),
        "---\nname: gh\nsummary: Work with GitHub from the terminal\n---\nBody.\n",
    )
    .unwrap();
    fs::create_dir_all(home.join("catalog/agents")).unwrap();
    fs::write(
        home.join("catalog/agents/helper.md"),
        "---\ndescription: helps\n---\n",
    )
    .unwrap();
    tmp
}

/// The machine-readable listing is versioned and minimal: subscriptions
/// per scope, counts only once a catalog is readable.
#[test]
#[allow(clippy::unwrap_used)]
fn marketplace_list_json_is_versioned_and_stable() {
    let tmp = fixture_home();
    let home = tmp.path().canonicalize().unwrap();
    let home = home.as_path();
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    let catalog_arg = catalog.display().to_string();

    let output = kendex(
        home,
        &project,
        &["marketplace", "subscribe", &catalog_arg, "--name", "cat"],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = kendex(
        home,
        &project,
        &["marketplace", "subscribe", "team/tools", "--name", "mkt"],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );

    let output = kendex(
        home,
        &project,
        &["marketplace", "list", "--json", "--scope", "project"],
    );
    assert!(output.status.success());
    let listed: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("list --json emits JSON");
    let expected = serde_json::json!({
        "schema": 1,
        "subscriptions": [
            {
                "scope": { "scope": "project", "root": project.display().to_string() },
                "name": "cat",
                "path": catalog_arg,
                "enabled": true,
                "counts": { "agent": 1, "skill": 1 }
            },
            {
                "scope": { "scope": "project", "root": project.display().to_string() },
                "name": "kendex",
                "repo": "vanillagreencom/kendex",
                "enabled": true
            },
            {
                "scope": { "scope": "project", "root": project.display().to_string() },
                "name": "mkt",
                "repo": "team/tools",
                "enabled": true
            }
        ]
    });
    assert_eq!(listed, expected, "{listed:#}");
}

/// The non-interactive half of browse: a subscription's packages listed for
/// scripts, the same seam the app's Packages page reads. Every core read
/// operation has a CLI verb.
#[test]
#[allow(clippy::unwrap_used)]
fn marketplace_browse_lists_a_subscriptions_packages() {
    let tmp = fixture_home();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog_arg = home.join("catalog").display().to_string();

    let subscribed = kendex(
        home,
        &project,
        &["marketplace", "subscribe", &catalog_arg, "--name", "cat"],
    );
    assert!(subscribed.status.success());

    let output = kendex(
        home,
        &project,
        &[
            "marketplace",
            "browse",
            "cat",
            "--json",
            "--scope",
            "project",
        ],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let listed: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("browse --json emits JSON");
    assert_eq!(listed["schema"], 1);
    let names: Vec<&str> = listed["packages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["package"]["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"gh"), "{listed:#}");
    assert!(names.contains(&"helper"), "{listed:#}");

    // The text listing shows each package's summary beside its name, the
    // same line the app's Packages row shows.
    let text = kendex(
        home,
        &project,
        &["marketplace", "browse", "cat", "--scope", "project"],
    );
    assert!(text.status.success());
    let stdout = String::from_utf8_lossy(&text.stdout);
    assert!(
        stdout.contains("cat::gh  (skill) [available]  — Work with GitHub from the terminal"),
        "{stdout}"
    );
}

/// Unsubscribe refuses without a decision when packages are installed, keeps
/// them as local forks with --keep-packages, and the source is gone either way.
#[test]
#[allow(clippy::unwrap_used)]
fn marketplace_unsubscribe_removes_or_keeps() {
    let tmp = fixture_home();
    let home = tmp.path();
    let project = home.join("dev/app");
    let catalog_arg = home.join("catalog").display().to_string();

    assert!(
        kendex(
            home,
            &project,
            &["marketplace", "subscribe", &catalog_arg, "--name", "cat"],
        )
        .status
        .success()
    );
    // Install a skill so the subscription is not empty (qualified, so the
    // bare-name search never reaches the unfetched default source).
    assert!(
        kendex(home, &project, &["add", "--skill", "cat::gh", "-y"])
            .status
            .success()
    );

    // No decision flag: refuses and says how.
    let refused = kendex(home, &project, &["marketplace", "unsubscribe", "cat"]);
    assert!(!refused.status.success());
    assert!(
        String::from_utf8_lossy(&refused.stderr).contains("--keep-packages"),
        "{}",
        String::from_utf8_lossy(&refused.stderr)
    );

    // Keep: the source goes, the skill stays declared from local.
    let kept = kendex(
        home,
        &project,
        &["marketplace", "unsubscribe", "cat", "--keep-packages"],
    );
    assert!(
        kept.status.success(),
        "{}",
        String::from_utf8_lossy(&kept.stderr)
    );
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(!manifest.contains("[sources.cat]"), "{manifest}");
    assert!(manifest.contains("source = \"local\""), "{manifest}");
}

/// Subscribing prints the preview line naming scope, alias, and target,
/// and a full URL declares a remote (the pre-fix heuristic read it as a
/// folder path).
#[test]
#[allow(clippy::unwrap_used)]
fn marketplace_subscribe_names_what_it_declares() {
    let tmp = fixture_home();
    let home = tmp.path();
    let project = home.join("dev/app");

    let output = kendex(
        home,
        &project,
        &[
            "marketplace",
            "subscribe",
            "https://gitlab.example.com/team/catalog.git",
        ],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let said = String::from_utf8_lossy(&output.stderr);
    assert!(said.contains("Subscribes"), "{said}");
    assert!(said.contains("'catalog'"), "{said}");
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(
        manifest.contains("repo = \"https://gitlab.example.com/team/catalog.git\""),
        "{manifest}"
    );
}
