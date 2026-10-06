//! Switching one package or one source on or off, and removing a source,
//! change what the verb names and hold every other package at the commit
//! its lock entry records, as `kendex remove` does. A catalog that moved on
//! since the install is not brought current by any of them.
//!
//! The fixture is `remove_locked`'s: `verify_records`'s consumer with the
//! catalog moved past the install by `refresh_locked`'s commit. A row that
//! switches something back on switches it off and commits first, while the
//! catalog still sits at the install. The control is the plan these verbs
//! made before this held them: planned at the catalog's tip, each rewrote
//! the moved skill, agent and command beside what it named.
//!
//! What a verb switches reads at the catalog's tip, so it switches even
//! where the mirror no longer holds the commit the record names: the
//! catalog's history rewritten past the install, read by a machine whose
//! mirror never fetched the old commit. Held there, the switched package
//! was skipped and the verb saved a manifest the disk did not match.
#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs;

use kendex_core::env::Env;
use kendex_core::model::{ItemKind, Scope};

use super::refresh_locked::{changed, move_the_catalog, record};
use super::verify_records::{World, commit, git, kendex, said, world};

/// How a row switches its subject: by a CLI verb, or by the app's toggle,
/// which calls the engine with one name and its kind.
enum Verb {
    Cli(&'static [&'static str]),
    App { enabled: bool },
}

/// What the verb names, and so which records it may change.
enum Subject {
    /// A package: its own lock entries, and the record of the source it
    /// reads fresh from.
    Package {
        kind: &'static str,
        name: &'static str,
        source: &'static str,
    },
    /// A source: its record, its sets' records and the entries of every
    /// package it declares.
    Source(&'static str),
}

/// Where the catalog stands when the verb runs.
#[derive(Clone, Copy)]
enum Catalog {
    /// Moved past the install; the mirror still holds the recorded commit.
    Moved,
    /// Rewritten so the recorded commit is gone, on a mirror fetched fresh.
    Rewritten,
}

struct Row {
    case: &'static str,
    /// Run and committed before the catalog moves.
    setup: Option<&'static [&'static str]>,
    catalog: Catalog,
    verb: Verb,
    subject: Subject,
    /// What every lock entry of a package the subject names says after the
    /// verb; `None` where it names none.
    enabled: Option<bool>,
    changed: &'static [&'static str],
}

const HOOK_PATHS: &[&str] = &[
    "kendex.toml",
    ".kendex-lock.json",
    ".kendex-generated.json",
    ".claude/hooks/guard.sh",
    ".claude/hooks/guard.sh.disabled",
    ".claude/settings.json",
];

const SOURCE_PATHS: &[&str] = &["kendex.toml", ".kendex-lock.json"];

const GUARD: Subject = Subject::Package {
    kind: "hook",
    name: "guard",
    source: "cat",
};

const DISABLE_GUARD: &[&str] = &["disable", "guard", "--scope", "project", "-y", "--leave"];
const ENABLE_GUARD: &[&str] = &["enable", "guard", "--scope", "project", "-y", "--leave"];

fn rows() -> Vec<Row> {
    vec![
        Row {
            case: "kendex disable",
            setup: None,
            catalog: Catalog::Moved,
            verb: Verb::Cli(DISABLE_GUARD),
            subject: GUARD,
            enabled: Some(false),
            changed: HOOK_PATHS,
        },
        Row {
            case: "kendex enable",
            setup: Some(DISABLE_GUARD),
            catalog: Catalog::Moved,
            verb: Verb::Cli(ENABLE_GUARD),
            subject: GUARD,
            enabled: Some(true),
            changed: HOOK_PATHS,
        },
        Row {
            case: "app toggle",
            setup: None,
            catalog: Catalog::Moved,
            verb: Verb::App { enabled: false },
            subject: GUARD,
            enabled: Some(false),
            changed: HOOK_PATHS,
        },
        Row {
            case: "kendex source remove",
            setup: None,
            catalog: Catalog::Moved,
            verb: Verb::Cli(&["source", "remove", "spare", "--leave"]),
            subject: Subject::Source("spare"),
            enabled: None,
            changed: SOURCE_PATHS,
        },
        Row {
            case: "kendex source disable",
            setup: None,
            catalog: Catalog::Moved,
            verb: Verb::Cli(&["source", "disable", "spare", "--leave"]),
            subject: Subject::Source("spare"),
            enabled: None,
            changed: SOURCE_PATHS,
        },
        Row {
            case: "kendex source enable",
            setup: Some(&["source", "disable", "spare", "--leave"]),
            catalog: Catalog::Moved,
            verb: Verb::Cli(&["source", "enable", "spare", "--leave"]),
            subject: Subject::Source("spare"),
            enabled: None,
            changed: SOURCE_PATHS,
        },
        Row {
            case: "kendex disable, recorded commit gone",
            setup: None,
            catalog: Catalog::Rewritten,
            verb: Verb::Cli(DISABLE_GUARD),
            subject: GUARD,
            enabled: Some(false),
            changed: HOOK_PATHS,
        },
        Row {
            case: "kendex enable, recorded commit gone",
            setup: Some(DISABLE_GUARD),
            catalog: Catalog::Rewritten,
            verb: Verb::Cli(ENABLE_GUARD),
            subject: GUARD,
            enabled: Some(true),
            changed: HOOK_PATHS,
        },
        Row {
            case: "app toggle, recorded commit gone",
            setup: None,
            catalog: Catalog::Rewritten,
            verb: Verb::App { enabled: false },
            subject: GUARD,
            enabled: Some(false),
            changed: HOOK_PATHS,
        },
        Row {
            case: "kendex source enable, recorded commit gone",
            setup: Some(&["source", "disable", "cat", "--leave"]),
            catalog: Catalog::Rewritten,
            verb: Verb::Cli(&["source", "enable", "cat", "--leave"]),
            subject: Subject::Source("cat"),
            enabled: Some(true),
            changed: &["kendex.toml", ".kendex-lock.json", ".kendex-generated.json"],
        },
    ]
}

/// The catalog's history rewritten so the installed commit is gone from
/// it, and the source cache cleared so the mirror is fetched fresh from
/// the rewritten history, as a second machine reading the committed
/// record fetches it.
fn rewrite_the_catalog(world: &World) {
    git(
        &world.catalog,
        &["commit", "-q", "--amend", "-m", "the catalog, rewritten"],
    );
    git(
        &world.catalog,
        &["reflog", "expire", "--expire=now", "--all"],
    );
    git(&world.catalog, &["gc", "-q", "--prune=now"]);
    let cache = Env::host_rooted(&world.home).source_cache_dir();
    fs::remove_dir_all(&cache).unwrap_or_else(|error| panic!("{}: {error}", cache.display()));
    let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
    assert!(fetched.status.success(), "{}", said(&fetched));
}

impl Subject {
    /// Whether one row of a record's `table` is the subject's to change.
    fn owns(&self, table: &str, key: &str, value: &serde_json::Value) -> bool {
        match (self, table) {
            (Subject::Package { source, .. } | Subject::Source(source), "sources") => {
                key == *source
            }
            (Subject::Package { kind, name, .. }, "entries") => {
                value["kind"] == *kind && value["name"] == *name
            }
            (Subject::Package { .. }, _) => false,
            (Subject::Source(source), _) => value["source"] == *source,
        }
    }
}

/// The rows of a record's `table` the subject owns, or every other one.
fn rows_of(
    record: &serde_json::Value,
    table: &str,
    subject: &Subject,
    owned: bool,
) -> Vec<(String, serde_json::Value)> {
    record[table]
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(key, value)| subject.owns(table, key, value) == owned)
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_toggle_or_source_change_holds_every_other_package_at_its_recorded_commit() {
    for row in rows() {
        let case = row.case;
        let world = world();
        if let Some(setup) = row.setup {
            let output = kendex(&world.home, &world.project, setup);
            assert!(output.status.success(), "{case}: {}", said(&output));
            commit(&world.project, "switched off before the catalog moves");
        }
        match row.catalog {
            Catalog::Moved => move_the_catalog(&world),
            Catalog::Rewritten => rewrite_the_catalog(&world),
        }
        let before = record(&world);

        let said = match row.verb {
            Verb::Cli(args) => {
                let output = kendex(&world.home, &world.project, args);
                assert!(output.status.success(), "{case}: {}", said(&output));
                said(&output)
            }
            Verb::App { enabled } => {
                let env = Env::host_rooted(&world.home);
                let scope = Scope::Project {
                    root: world.project.clone(),
                };
                let report = kendex_core::engine::ops::toggle(
                    &env,
                    &scope,
                    &["guard".to_owned()],
                    Some(ItemKind::Hook),
                    enabled,
                    None,
                )
                .unwrap();
                kendex_core::apply::execute(&env, &report.plan).unwrap();
                String::new()
            }
        };

        assert_eq!(
            changed(&world),
            row.changed
                .iter()
                .map(|path| (*path).to_owned())
                .collect::<BTreeSet<_>>(),
            "{case}: {said}"
        );
        let after = record(&world);
        if let Some(enabled) = row.enabled {
            let switched = rows_of(&after, "entries", &row.subject, true);
            assert!(!switched.is_empty(), "{case}: {after}");
            for (_, entry) in switched {
                assert_eq!(entry["enabled"], enabled, "{case}: {entry}");
            }
        }
        for table in ["entries", "sources", "bundles"] {
            assert_eq!(
                rows_of(&after, table, &row.subject, false),
                rows_of(&before, table, &row.subject, false),
                "{case}: {table}"
            );
        }
    }
}
