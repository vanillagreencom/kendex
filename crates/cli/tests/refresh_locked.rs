//! `kendex refresh --locked`: a re-render of a project-side change reads
//! every package that follows its source at the commit the install record
//! names, so a catalog that moved on since the install changes nothing the
//! catalog renders and nothing the record says about where it was read.
//!
//! The fixture is `verify_records`'s consumer, whose record carries an
//! item of every kind, a set, a Pi extension and a source nothing names.
//! The control is the same refresh without `--locked` on the same tree,
//! which brings the catalog current and rewrites what it renders.
#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs;

use super::verify_records::{World, commit, git, kendex, said, world, write};

const RECORD: &str = ".kendex-lock.json";

/// The tracked paths the working tree changed since the last commit.
fn changed(world: &World) -> BTreeSet<String> {
    git(&world.project, &["status", "--porcelain", "--no-renames"])
        .lines()
        .map(|line| line[3..].to_owned())
        .collect()
}

/// The record with the one agent's content hashes taken out: everything a
/// project-side instruction may change in it, and nothing a catalog does.
#[allow(clippy::unwrap_used)]
fn record_without_agent_hashes(world: &World, agent: &str) -> serde_json::Value {
    let text = fs::read_to_string(world.project.join(RECORD)).unwrap();
    let mut record: serde_json::Value = serde_json::from_str(&text).unwrap();
    for entry in record["entries"].as_object_mut().unwrap().values_mut() {
        if entry["kind"] == "agent" && entry["name"] == agent {
            let entry = entry.as_object_mut().unwrap();
            entry.remove("sourceHash");
            entry.remove("renderedHash");
        }
    }
    record
}

/// A catalog commit past the install that changes every kind the consumer
/// renders from it, fetched into the mirror.
#[allow(clippy::unwrap_used)]
fn move_the_catalog(world: &World) {
    for (path, text) in [
        ("skills/second/SKILL.md", "\nA paragraph added later.\n"),
        ("agents/review.md", "\nAlso read the tests.\n"),
        ("hooks/guard.sh", "# a later comment\n"),
        ("commands/second.md", "Then tag it.\n"),
        (
            "pi-extensions/@scope/widgets/index.js",
            "export const later = 2;\n",
        ),
    ] {
        let path = world.catalog.join(path);
        let before = fs::read_to_string(&path).unwrap();
        write(&path, &format!("{before}{text}"));
    }
    commit(&world.catalog, "the catalog moves on");
    let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
    assert!(fetched.status.success(), "{}", said(&fetched));
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_locked_refresh_renders_a_project_change_at_the_recorded_catalog() {
    let world = world();
    move_the_catalog(&world);

    let manifest = world.project.join("kendex.toml");
    let declared = fs::read_to_string(&manifest).unwrap();
    write(
        &manifest,
        &format!("{declared}\n[agent-additional-instructions]\nreview = \"Cite the issue.\"\n"),
    );
    commit(&world.project, "a project-side instruction");
    let recorded = record_without_agent_hashes(&world, "review");

    let locked = kendex(
        &world.home,
        &world.project,
        &[
            "refresh", "--scope", "project", "--locked", "--yes", "--leave",
        ],
    );
    assert!(locked.status.success(), "{}", said(&locked));
    let agent = fs::read_to_string(world.project.join(".claude/agents/review.md")).unwrap();
    assert!(agent.contains("Cite the issue."), "{agent}");
    assert!(!agent.contains("Also read the tests."), "{agent}");
    assert_eq!(
        changed(&world),
        BTreeSet::from([RECORD.to_owned(), ".claude/agents/review.md".to_owned()]),
        "{}",
        said(&locked)
    );
    assert_eq!(record_without_agent_hashes(&world, "review"), recorded);

    // The control: the same tree refreshed without --locked brings the
    // catalog current, so what the catalog renders moves.
    let current = kendex(
        &world.home,
        &world.project,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    assert!(current.status.success(), "{}", said(&current));
    let moved = changed(&world);
    assert!(
        moved.contains(".claude/skills/second/SKILL.md"),
        "{moved:?}\n{}",
        said(&current)
    );
    assert_ne!(record_without_agent_hashes(&world, "review"), recorded);
}
