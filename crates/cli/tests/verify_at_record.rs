//! `kendex verify --at-record`: each package that follows its source is
//! rendered at the commit the install record names, and each such commit
//! is held to the history of the one its source resolves to now and, with
//! `--base`, to not being older than the base revision's record.
//!
//! The fixture is `verify_records`'s consumer. The must-fail controls are
//! the history and floor checks in `attest::record`: each off-history and
//! rollback row passes with its check removed.
#![cfg(unix)]

use std::fs;

use kendex_core::attest::Document;

use super::verify_records::{
    INSTALLED, RECORD, World, commit, edit_json, git, kendex, row, said, verify, world, write,
};

/// One `--at-record` run of the project scope, with the document it
/// printed.
#[allow(clippy::unwrap_used)]
fn at_record(world: &World, base: Option<&str>) -> (std::process::Output, Document) {
    let mut args = vec!["verify", "--scope", "project", "--json", "--at-record"];
    if let Some(base) = base {
        args.extend(["--base", base]);
    }
    let output = kendex(&world.home, &world.project, &args);
    let document: Document = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|error| panic!("the document does not parse: {error}\n{}", said(&output)));
    (output, document)
}

/// One edit to the record's JSON.
type RecordEdit = Box<dyn Fn(&mut serde_json::Value)>;

/// The stale list as (source, recorded, resolved).
fn trails(document: &Document) -> Vec<(&str, &str, &str)> {
    document
        .stale
        .iter()
        .map(|stale| {
            (
                stale.source.as_str(),
                stale.recorded.as_str(),
                stale.resolved.as_str(),
            )
        })
        .collect()
}

/// The record row's detail, which names each problem the record check
/// found.
#[allow(clippy::unwrap_used)]
fn record_detail(document: &Document) -> String {
    row(document, "record", RECORD, None)
        .unwrap()
        .detail
        .clone()
        .unwrap_or_default()
}

#[allow(clippy::unwrap_used)]
fn head(dir: &std::path::Path) -> String {
    git(dir, &["rev-parse", "HEAD"]).trim().to_owned()
}

/// Appends a paragraph to a catalog file.
#[allow(clippy::unwrap_used)]
fn append(world: &World, path: &str, text: &str) {
    let path = world.catalog.join(path);
    let before = fs::read_to_string(&path).unwrap();
    write(&path, &format!("{before}{text}"));
}

/// A catalog that moved on past the install, a skill and a Pi extension
/// both changed, stales the plain verify, while the same record weighed
/// at its own commits is clean and lists every source commit it trails.
/// A record that is current trails nothing. A commit the mirror holds off
/// the declared revision's history, here a side branch whose bytes are
/// the installed ones, renders identically, so only the history check
/// refuses it, for an item's entries and for a set alike.
#[test]
#[allow(clippy::unwrap_used)]
fn at_record_weighs_a_record_the_source_moved_past_on_its_own_commits() {
    let world = world();
    let (current, document) = at_record(&world, None);
    assert!(current.status.success(), "{}", said(&current));
    assert_eq!(trails(&document), Vec::new(), "{document:?}");

    let installed_at = head(&world.catalog);
    git(&world.catalog, &["checkout", "-q", "-b", "side"]);
    write(&world.catalog.join("NOTES.md"), "A side note.\n");
    commit(&world.catalog, "a side branch");
    let side = head(&world.catalog);
    git(&world.catalog, &["checkout", "-q", "main"]);
    append(
        &world,
        "skills/second/SKILL.md",
        "\nA paragraph added later.\n",
    );
    append(
        &world,
        "pi-extensions/@scope/widgets/index.js",
        "export const later = 2;\n",
    );
    commit(&world.catalog, "the catalog moves on");
    let tip = head(&world.catalog);
    let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
    assert!(fetched.status.success(), "{}", said(&fetched));

    let (plain, _) = verify(&world, None);
    assert!(!plain.status.success(), "{}", said(&plain));
    let (held, document) = at_record(&world, None);
    assert!(held.status.success(), "{}", said(&held));
    assert_eq!(
        trails(&document),
        vec![
            ("cat", installed_at.as_str(), tip.as_str()),
            ("picat", installed_at.as_str(), tip.as_str()),
            ("spare", installed_at.as_str(), tip.as_str()),
        ],
        "{document:?}"
    );

    let project = world.project.clone();
    let off_history: [(&str, RecordEdit, String); 2] = [
        (
            "an item's entries",
            Box::new({
                let side = side.clone();
                move |lock| {
                    for key in ["skill:second:claude", "skill:second:codex"] {
                        lock["entries"][key]["sourceCommit"] =
                            serde_json::Value::String(side.clone());
                    }
                }
            }),
            format!("skill second: held at {side} is not on the declared revision's history"),
        ),
        (
            "a set",
            Box::new({
                let side = side.clone();
                move |lock| {
                    lock["bundles"]["starter"]["commit"] = serde_json::Value::String(side.clone())
                }
            }),
            format!("set starter: held at {side} is not on the declared revision's history"),
        ),
    ];
    for (label, edit, problem) in off_history {
        git(&project, &["checkout", "-q", "--", RECORD]);
        edit_json(&project.join(RECORD), edit);
        let (output, document) = at_record(&world, None);
        assert!(!output.status.success(), "{label}: {}", said(&output));
        let detail = record_detail(&document);
        assert!(detail.contains(&problem), "{label}: {detail}");
    }
}

/// A change that puts back an older install, record and renders together,
/// renders clean at its own commits, and the base revision's record is
/// what refuses it: every held commit is at least as new as the one that
/// record names.
#[test]
#[allow(clippy::unwrap_used)]
fn at_record_refuses_a_record_older_than_the_base_record() {
    let world = world();
    append(
        &world,
        "skills/second/SKILL.md",
        "\nA paragraph added later.\n",
    );
    commit(&world.catalog, "the catalog moves on");
    for args in [&["source", "refresh"][..], &["apply", "-y", "--leave"]] {
        let output = kendex(&world.home, &world.project, args);
        assert!(
            output.status.success(),
            "kendex {args:?}: {}",
            said(&output)
        );
    }
    commit(&world.project, "brought current");
    git(&world.project, &["tag", "current"]);
    git(&world.project, &["checkout", "-q", INSTALLED, "--", "."]);
    commit(&world.project, "the older install put back");

    let (unbounded, _) = at_record(&world, None);
    assert!(unbounded.status.success(), "{}", said(&unbounded));
    let (bounded, document) = at_record(&world, Some("current"));
    assert!(!bounded.status.success(), "{}", said(&bounded));
    let detail = record_detail(&document);
    assert!(
        detail.contains("skill second: held at")
            && detail.contains("the commit the base revision's record names"),
        "{detail}"
    );
}

/// A declaration with a revision of its own is read at it and never held,
/// so its commit answers to that revision alone: an agent pinned to a
/// side branch stays clean after the source moves on. The fixture's set
/// carries a member the manifest also declares, so a revision on the set
/// alone asks for that member at two revisions under either reading and
/// is no case of this surface's.
#[test]
#[allow(clippy::unwrap_used)]
fn at_record_leaves_a_declared_revision_to_itself() {
    let world = world();
    git(&world.catalog, &["checkout", "-q", "-b", "side"]);
    write(&world.catalog.join("NOTES.md"), "A side note.\n");
    commit(&world.catalog, "a side branch");
    let side = head(&world.catalog);
    git(&world.catalog, &["checkout", "-q", "main"]);
    let manifest = world.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    let pinned = text.replace(
        "[agents.review]\nsource = \"cat\"\n",
        &format!("[agents.review]\nsource = \"cat\"\nrev = \"{side}\"\n"),
    );
    assert_ne!(pinned, text, "the manifest took the pin");
    write(&manifest, &pinned);
    for args in [&["source", "refresh"][..], &["apply", "-y", "--leave"]] {
        let output = kendex(&world.home, &world.project, args);
        assert!(
            output.status.success(),
            "kendex {args:?}: {}",
            said(&output)
        );
    }
    commit(&world.project, "pinned");
    append(
        &world,
        "skills/second/SKILL.md",
        "\nA paragraph added later.\n",
    );
    commit(&world.catalog, "the catalog moves on");
    let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
    assert!(fetched.status.success(), "{}", said(&fetched));

    let (output, document) = at_record(&world, None);
    assert!(output.status.success(), "{}", said(&output));
    assert_eq!(record_detail(&document), "", "{document:?}");
}
