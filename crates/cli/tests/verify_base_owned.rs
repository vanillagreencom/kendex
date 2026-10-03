//! `kendex verify --json --base REV`: `base_owned`, the whole files and
//! trees the base revision's install record names. No row prints a
//! position the head no longer renders, so a reader granting a retired
//! render's deletion reads this field and nothing else.
//!
//! The must-fail control for the list is a reader that takes the base
//! revision's inventory for its whole positions: the inventory also lists
//! the shared registry file a hook writes keys in, and the first test
//! fails on `.claude/settings.json`. The control for the scope rows is a
//! field read only where the run checks the project scope alone: the
//! `all` row, which checks the global scope beside it, fails.
#![cfg(unix)]

use kendex_core::attest::Document;
use kendex_core::engine::Owns;
use kendex_core::lock::LOCK_VERSION;

use super::verify_records::{
    INSTALLED, RECORD, commit, edit_json, git, retired, said, verify_scope, world,
};
use crate::test_util::source_path;

/// What a document says the base record owned whole, as (path, owns).
type Owned<'a> = Option<Vec<(&'a str, Owns)>>;

/// The base positions a document prints, as (path, owns).
fn owned(document: &Document) -> Owned<'_> {
    document.base_owned.as_ref().map(|owned| {
        owned
            .iter()
            .map(|position| (position.path.as_str(), position.owns))
            .collect()
    })
}

/// A project that installed an agent, a skill and a scripted hook, then
/// retired the agent and the skill: the base record's whole file and tree
/// positions are listed, each as the shape the base revision holds, while
/// the head prints no row for either. The hook's registry file is a shared
/// file the record keeps a registration for, never a whole position, so it
/// is not listed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_retired_render_is_listed_as_the_base_record_owned_it() {
    let world = world();
    let cat = format!("[sources.cat]\n{}\n", source_path(&world.catalog));
    let guard = "[hooks.guard]\nsource = \"cat\"\n";
    let before = format!(
        "{cat}[agents.review]\nsource = \"cat\"\n\n[skills.second]\nsource = \"cat\"\n\n{guard}"
    );
    let after = format!("{cat}{guard}");
    let (output, document) = retired(&world, "owned", &before, &after, None);
    assert!(output.status.success(), "{}", said(&output));
    assert_eq!(
        owned(&document),
        Some(vec![
            (".claude/agents/review.md", Owns::File),
            (".claude/hooks/guard.sh", Owns::File),
            (".claude/skills/second", Owns::Tree),
        ]),
        "{document:?}"
    );
    let shared = ".claude/settings.json";
    assert!(
        document
            .base_owned
            .iter()
            .flatten()
            .all(|position| position.path != shared),
        "{shared} is a shared registry file: {document:?}"
    );
    let printed: Vec<&str> = document
        .rows
        .iter()
        .flat_map(|row| row.positions.iter())
        .map(|position| position.path.as_str())
        .collect();
    assert!(
        !printed.contains(&".claude/agents/review.md")
            && !printed.contains(&".claude/skills/second"),
        "the head still prints a retired position: {printed:?}"
    );
}

/// The whole positions the fixture consumer's record names at the
/// installed tag: every skill tree, the command installed as a skill tree,
/// the agent file and the hook's script. Its Pi package is copied, and its
/// MCP server, plugin and Gemini shim write keys in shared files, so none
/// of those is here.
fn installed() -> Vec<(&'static str, Owns)> {
    vec![
        (".agents/skills/second", Owns::Tree),
        (".agents/skills/second__command", Owns::Tree),
        (".claude/agents/review.md", Owns::File),
        (".claude/hooks/guard.sh", Owns::File),
        (".claude/skills/data-science__eda", Owns::Tree),
        (".claude/skills/second", Owns::Tree),
        (".opencode/skills/data-science-eda", Owns::Tree),
    ]
}

/// The field is left out wherever nothing was read and present wherever
/// the base record was, one row per answer: no base, a base the project
/// cannot resolve, a base from before kendex wrote a record, a base whose
/// record another lock version wrote, and the global scope; then the
/// project scope alone and beside the global scope. An unread base is
/// unknown, never an empty list a reader could take for none owned.
#[test]
#[allow(clippy::unwrap_used)]
fn the_field_is_left_out_wherever_no_base_record_was_read() {
    let world = world();
    git(
        &world.project,
        &["checkout", "-q", "-B", "older", INSTALLED],
    );
    edit_json(&world.project.join(RECORD), |lock| {
        lock["version"] = (LOCK_VERSION - 1).into();
    });
    commit(&world.project, "the record as an earlier kendex wrote it");
    git(&world.project, &["checkout", "-q", "-B", "case", INSTALLED]);
    let before_kendex = format!("{INSTALLED}~1");
    let rows: [(&str, &str, Option<&str>, Owned); 7] = [
        ("no base", "project", None, None),
        (
            "a base the project cannot resolve",
            "project",
            Some("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"),
            None,
        ),
        (
            "a base from before kendex wrote a record",
            "project",
            Some(&before_kendex),
            None,
        ),
        (
            "a base record another lock version wrote",
            "project",
            Some("older"),
            None,
        ),
        ("the global scope", "global", Some(INSTALLED), None),
        (
            "the project scope",
            "project",
            Some(INSTALLED),
            Some(installed()),
        ),
        (
            "the project beside the global scope",
            "all",
            Some(INSTALLED),
            Some(installed()),
        ),
    ];
    for (label, scope, base, want) in rows {
        let (output, document) = verify_scope(&world, scope, base);
        assert_eq!(owned(&document), want, "{label}: {}", said(&output));
    }
}
