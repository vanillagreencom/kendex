//! `kendex index --json`: the per-marketplace summary the community
//! directory consumes. What it says a marketplace offers must be exactly
//! what subscribing finds, because both read through the same core — the
//! last test pins that sentence.
#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(home)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::expect_used)]
fn index_json(home: &Path, dir: &Path) -> serde_json::Value {
    let output = kendex(
        home,
        &["index", dir.to_str().expect("utf-8 path"), "--json"],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("stdout is the JSON summary")
}

#[allow(clippy::unwrap_used)]
fn skill(root: &Path, name: &str, header_extra: &str) {
    let dir = root.join("skills").join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n{header_extra}---\nBody.\n"),
    )
    .unwrap();
}

/// A plain directory of skills — no kendex.toml, no git — indexes through
/// discovery, with descriptions and tags read from each item's own header.
#[test]
#[allow(clippy::unwrap_used)]
fn a_discovered_layout_indexes_with_descriptions_and_tags() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("tools");
    fs::create_dir_all(&root).unwrap();
    skill(&root, "gh", "tags: [git]\n");
    skill(&root, "deploy", "");

    let json = index_json(tmp.path(), &root);
    assert_eq!(json["schema"], 1);
    assert_eq!(json["name"], "tools");
    assert_eq!(json["counts"]["packages"], 2);
    assert_eq!(json["counts"]["bundles"], 0);
    assert_eq!(json["checked"]["breakage"], 0);
    assert_eq!(json["checked"]["held_back"], 0);
    let packages = json["packages"].as_array().unwrap();
    let gh = packages.iter().find(|p| p["name"] == "gh").unwrap();
    assert_eq!(gh["kind"], "skill");
    assert_eq!(gh["description"], "about gh");
    assert_eq!(gh["tags"], serde_json::json!(["git"]));
    assert_eq!(gh["safety"]["verdict"], "clean");
    assert!(gh["safety"]["score"].as_u64().unwrap() <= 100);
    let found = json["found"].as_array().unwrap();
    assert!(
        found
            .iter()
            .any(|row| row["root"] == "skills" && row["kind"] == "skill" && row["count"] == 2),
        "{json}"
    );
}

/// A declared marketplace: `[marketplace]` metadata is read (and capped),
/// bundles list their members, and every declared kind shows up.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_marketplace_indexes_metadata_and_bundles() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("team");
    fs::create_dir_all(root.join("agents")).unwrap();
    skill(&root, "gh", "");
    fs::write(
        root.join("agents/helper.md"),
        "---\ndescription: helps\n---\nBody.\n",
    )
    .unwrap();
    let long = "d".repeat(600);
    fs::write(
        root.join("kendex.toml"),
        format!(
            "[marketplace]\nname = \"Team \\u0007 Tools\"\ndescription = \"{long}\"\n\
             author = \"Ana\"\nlicense = \"MIT\"\nhomepage = \"https://example.com\"\n\
             tags = [\"ai\"]\n\n[bundles.starter]\ndescription = \"the basics\"\n\
             agents = [\"helper\"]\nskills = [\"gh\"]\n"
        ),
    )
    .unwrap();

    let json = index_json(tmp.path(), &root);
    let name = json["name"].as_str().unwrap();
    assert!(!name.contains('\u{7}'), "{name:?}");
    assert!(name.contains("\\u{7}"), "{name:?}");
    assert_eq!(json["description"].as_str().unwrap().chars().count(), 500);
    assert_eq!(json["author"], "Ana");
    assert_eq!(json["license"], "MIT");
    assert_eq!(json["homepage"], "https://example.com");
    assert_eq!(json["tags"], serde_json::json!(["ai"]));
    assert_eq!(json["counts"]["packages"], 2);
    assert_eq!(json["counts"]["bundles"], 1);
    let bundle = &json["bundles"].as_array().unwrap()[0];
    assert_eq!(bundle["name"], "starter");
    assert_eq!(bundle["description"], "the basics");
    let members = bundle["members"].as_array().unwrap();
    assert!(
        members
            .iter()
            .any(|m| m["kind"] == "agent" && m["name"] == "helper"),
        "{json}"
    );
    assert!(
        members
            .iter()
            .any(|m| m["kind"] == "skill" && m["name"] == "gh"),
        "{json}"
    );
}

/// The invariant the directory rests on: what the summary says a
/// marketplace offers is exactly what subscribing finds, because both read
/// through the same core.
#[test]
#[allow(clippy::unwrap_used)]
fn the_summary_offers_exactly_what_list_items_offers() {
    use kendex_core::model::ItemKind;
    use kendex_core::source::{list_items, source_config};
    use kendex_core::source_read::SealedSource;

    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("mixed");
    fs::create_dir_all(root.join("agents")).unwrap();
    skill(&root, "gh", "");
    skill(&root, "deploy", "");
    fs::write(
        root.join("agents/helper.md"),
        "---\ndescription: helps\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        root.join("kendex.toml"),
        "[bundles.all]\nskills = [\"gh\"]\n",
    )
    .unwrap();

    let json = index_json(tmp.path(), &root);
    let mut indexed: Vec<(String, String)> = json["packages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| {
            (
                p["kind"].as_str().unwrap().to_owned(),
                p["name"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    indexed.sort();

    let sealed = SealedSource::open(&root).unwrap();
    let config = source_config(&sealed, "mixed").unwrap();
    let mut offered: Vec<(String, String)> = Vec::new();
    for kind in [
        ItemKind::Agent,
        ItemKind::Skill,
        ItemKind::Hook,
        ItemKind::Command,
        ItemKind::McpServer,
    ] {
        for name in list_items(&sealed, &config, kind) {
            offered.push((kind.name().to_owned(), name));
        }
    }
    offered.sort();
    assert_eq!(indexed, offered);
    assert!(!offered.is_empty());
}

/// `kendex marketplace check` is `check --catalog --strict` under its own
/// name: same verdict, same exit code, stricter than the plain check.
#[test]
#[allow(clippy::unwrap_used)]
fn marketplace_check_exits_exactly_like_the_strict_catalog_check() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("cat");
    // A skill without a description loads everywhere — an advisory, which
    // only strict runs fail on.
    let dir = root.join("skills/plain");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), "---\nname: plain\n---\nBody.\n").unwrap();
    let dir_arg = root.to_str().unwrap();

    let plain = kendex(tmp.path(), &["check", "--catalog", dir_arg]);
    let strict = kendex(tmp.path(), &["check", "--catalog", dir_arg, "--strict"]);
    let alias = kendex(tmp.path(), &["marketplace", "check", dir_arg]);
    assert!(plain.status.success());
    assert_eq!(strict.status.code(), Some(1));
    assert_eq!(alias.status.code(), strict.status.code());
    let said = String::from_utf8_lossy(&alias.stderr).into_owned();
    assert!(said.contains("1 problem(s)"), "{said}");
}
