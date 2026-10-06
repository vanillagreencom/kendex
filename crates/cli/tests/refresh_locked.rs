//! `kendex refresh --locked`: a re-render of a project-side change reads
//! every package that follows its source at the commit the install record
//! names, so a catalog that moved on since the install changes nothing the
//! catalog renders and nothing the record says about where it was read.
//!
//! The fixture is `verify_records`'s consumer, whose record carries an
//! item of every kind, a set, a Pi extension and a source nothing names.
//! The control is the same refresh without `--locked` on the same tree,
//! which brings the catalog current and rewrites what it renders.
//!
//! What the record cannot speak for still reads where the source sits now:
//! an item it has no entry for, and a source declared at another revision
//! than its entry was written for.
#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs;

use super::verify_records::{World, commit, git, kendex, said, world, write};

const RECORD: &str = ".kendex-lock.json";

/// The tracked paths the working tree changed since the last commit.
pub(crate) fn changed(world: &World) -> BTreeSet<String> {
    git(&world.project, &["status", "--porcelain", "--no-renames"])
        .lines()
        .map(|line| line[3..].to_owned())
        .collect()
}

#[allow(clippy::unwrap_used)]
pub(crate) fn record(world: &World) -> serde_json::Value {
    serde_json::from_str(&fs::read_to_string(world.project.join(RECORD)).unwrap()).unwrap()
}

/// The catalog's checked-out commit.
fn catalog_tip(world: &World) -> String {
    git(&world.catalog, &["rev-parse", "HEAD"])
        .trim()
        .to_owned()
}

/// The record with the one agent's content hashes taken out: everything a
/// project-side instruction may change in it, and nothing a catalog does.
#[allow(clippy::unwrap_used)]
fn record_without_agent_hashes(world: &World, agent: &str) -> serde_json::Value {
    let mut record = record(world);
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
pub(crate) fn move_the_catalog(world: &World) {
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

/// A Pi package whose settings registration was removed (the Pi extension
/// manager's settings-only uninstall) after the catalog moved is
/// reinstalled and recorded at the commit the record names: the install
/// completes and no recorded commit moves.
#[test]
#[allow(clippy::unwrap_used)]
fn a_locked_refresh_reinstalls_an_unregistered_pi_package_at_the_recorded_commit() {
    let world = world();
    move_the_catalog(&world);
    let settings = world.project.join(".pi/settings.json");
    write(&settings, "{\"packages\": []}\n");
    commit(&world.project, "the registration is removed");
    let before = record(&world);

    let locked = kendex(
        &world.home,
        &world.project,
        &[
            "refresh", "--scope", "project", "--locked", "--yes", "--leave",
        ],
    );
    assert!(locked.status.success(), "{}", said(&locked));
    let registered = fs::read_to_string(&settings).unwrap();
    assert!(
        registered.contains("packages/@scope/widgets"),
        "{registered}"
    );
    let index =
        fs::read_to_string(world.project.join(".pi/packages/@scope/widgets/index.js")).unwrap();
    assert!(!index.contains("later"), "{index}");
    let after = record(&world);
    assert_eq!(after["sources"], before["sources"]);
    let widgets = |record: &serde_json::Value| {
        record["entries"]
            .as_object()
            .unwrap()
            .values()
            .find(|entry| entry["kind"] == "pi-extension")
            .cloned()
            .unwrap()
    };
    let (was, is) = (widgets(&before), widgets(&after));
    for field in ["sourceCommit", "sourceHash", "renderedHash"] {
        assert!(is[field].is_string(), "{field}: {is}");
        assert_eq!(is[field], was[field], "{field}");
    }
}

/// An item the record has no entry for resolves at the catalog tip, and
/// its source's record moves there with it; a sibling the record places
/// still renders at its recorded commit.
#[test]
#[allow(clippy::unwrap_used)]
fn a_locked_refresh_reads_a_new_item_and_its_source_at_the_tip() {
    let world = world();
    write(
        &world.catalog.join("skills/third/SKILL.md"),
        "---\nname: third\ndescription: a third skill\n---\n# Third\n\nArrived later.\n",
    );
    move_the_catalog(&world);
    let manifest = world.project.join("kendex.toml");
    let declared = fs::read_to_string(&manifest).unwrap();
    write(
        &manifest,
        &format!("{declared}\n[skills.third]\nsource = \"cat\"\nharnesses = [\"claude\"]\n"),
    );
    commit(&world.project, "a new catalog skill");

    let locked = kendex(
        &world.home,
        &world.project,
        &[
            "refresh", "--scope", "project", "--locked", "--yes", "--leave",
        ],
    );
    assert!(locked.status.success(), "{}", said(&locked));
    let third = fs::read_to_string(world.project.join(".claude/skills/third/SKILL.md")).unwrap();
    assert!(third.contains("Arrived later."), "{third}");
    let moved = changed(&world);
    assert!(
        !moved.contains(".claude/skills/second/SKILL.md"),
        "{moved:?}\n{}",
        said(&locked)
    );
    assert_eq!(
        record(&world)["sources"]["cat"]["commit"],
        catalog_tip(&world).as_str()
    );
}

/// A source declared at another revision than its record entry was
/// written for is read at that revision, not kept: here `spare`, which no
/// item names, so nothing in the pass resolves it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_locked_refresh_reads_a_redeclared_source_afresh() {
    let world = world();
    move_the_catalog(&world);
    let before = record(&world);
    let manifest = world.project.join("kendex.toml");
    let declared = fs::read_to_string(&manifest).unwrap();
    let redeclared = declared.replacen("[sources.spare]\n", "[sources.spare]\nrev = \"main\"\n", 1);
    assert_ne!(redeclared, declared);
    write(&manifest, &redeclared);
    commit(&world.project, "spare follows main");

    let locked = kendex(
        &world.home,
        &world.project,
        &[
            "refresh", "--scope", "project", "--locked", "--yes", "--leave",
        ],
    );
    assert!(locked.status.success(), "{}", said(&locked));
    let spare = &record(&world)["sources"]["spare"];
    assert_eq!(spare["repo"], before["sources"]["spare"]["repo"]);
    assert_eq!(spare["rev"], "main");
    assert_eq!(spare["commit"], catalog_tip(&world).as_str());
}
