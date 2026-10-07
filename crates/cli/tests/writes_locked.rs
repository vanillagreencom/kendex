//! Unsubscribing from one marketplace, adding or subscribing to another,
//! and switching the package checks on change what the verb names and hold
//! every other package at the commit its lock entry records, as
//! `kendex apply` does. A catalog that moved on since the install is not
//! brought current by any of them.
//!
//! The fixture is `toggle_locked`'s: `verify_records`'s consumer with the
//! catalog moved past the install by `refresh_locked`'s commit. Every verb
//! here names something other than that catalog: the `market` folder
//! source, a folder source new to the project, or the package check. The
//! control is the plan these verbs made before this held them: planned at
//! the catalog's tip, each rewrote the moved skill, agent and command beside
//! what it named, and the package-check confirmation counted those rewrites
//! as work already waiting.
#![cfg(unix)]

use std::collections::BTreeSet;
use std::path::Path;

use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::refresh_locked::{changed, move_the_catalog, record};
use super::verify_records::{World, kendex, said, world, write};

/// The aliases the moved catalog is declared under: every record row that
/// names one is a package, set or source no verb here names.
const MOVED_SOURCES: &[&str] = &["cat", "picat", "spare"];

/// Each render the moved catalog's commit changes.
const MOVED_RENDERS: &[&str] = &[
    ".claude/skills/second/SKILL.md",
    ".agents/skills/second/SKILL.md",
    ".agents/skills/second__command/SKILL.md",
    ".claude/agents/review.md",
    ".claude/hooks/guard.sh",
];

struct Row {
    case: &'static str,
    /// A folder catalog to lay down beside the project before the verb
    /// runs, at this name under the fixture home.
    catalog: Option<&'static str>,
    args: &'static [&'static str],
    /// Paths the verb has to change, so a row that did nothing fails.
    touches: &'static [&'static str],
}

const ROWS: &[Row] = &[
    Row {
        case: "kendex marketplace unsubscribe --remove-packages",
        catalog: None,
        args: &[
            "marketplace",
            "unsubscribe",
            "market",
            "--remove-packages",
            "--leave",
        ],
        touches: &["kendex.toml", ".claude/skills/data-science__eda/SKILL.md"],
    },
    Row {
        case: "kendex marketplace unsubscribe --keep-packages",
        catalog: None,
        args: &[
            "marketplace",
            "unsubscribe",
            "market",
            "--keep-packages",
            "--leave",
        ],
        touches: &["kendex.toml"],
    },
    Row {
        case: "kendex source add",
        catalog: Some("extra"),
        args: &["source", "add", "extra", "../../extra", "--leave"],
        touches: &["kendex.toml"],
    },
    Row {
        case: "kendex marketplace subscribe",
        catalog: Some("extra"),
        args: &["marketplace", "subscribe", "../../extra", "--leave"],
        touches: &["kendex.toml"],
    },
    Row {
        case: "kendex drift-hook",
        catalog: None,
        args: &["drift-hook", "--scope", "project", "-y", "--leave"],
        touches: &["kendex.toml", ".claude/settings.json"],
    },
];

/// A folder catalog with one skill, which nothing in the project declares.
fn lay_down_catalog(root: &Path) {
    write(&root.join("kendex.toml"), "[catalog]\n");
    write(
        &root.join("skills/third/SKILL.md"),
        "---\nname: third\ndescription: a third skill\n---\n# Third\n",
    );
}

/// The rows of a record's `table` that name one of the moved catalog's
/// aliases.
fn moved_rows(record: &serde_json::Value, table: &str) -> Vec<(String, serde_json::Value)> {
    record[table]
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(key, value)| {
            let source = match table {
                "sources" => key.as_str(),
                _ => value["source"].as_str().unwrap_or_default(),
            };
            MOVED_SOURCES.contains(&source)
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

/// The moved renders among the paths the working tree changed.
fn moved_renders_changed(world: &World) -> BTreeSet<String> {
    changed(world)
        .into_iter()
        .filter(|path| MOVED_RENDERS.contains(&path.as_str()))
        .collect()
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_write_naming_another_source_holds_the_moved_catalog_at_its_recorded_commit() {
    for row in ROWS {
        let case = row.case;
        let world = world();
        if let Some(name) = row.catalog {
            lay_down_catalog(&world.home.join(name));
        }
        move_the_catalog(&world);
        let before = record(&world);

        let output = kendex(&world.home, &world.project, row.args);
        assert!(output.status.success(), "{case}: {}", said(&output));

        let touched = changed(&world);
        for path in row.touches {
            assert!(
                touched.contains(*path),
                "{case}: {path} unchanged in {touched:?}"
            );
        }
        assert_eq!(
            moved_renders_changed(&world),
            BTreeSet::new(),
            "{case}: {}",
            said(&output)
        );
        let after = record(&world);
        for table in ["entries", "sources", "bundles"] {
            assert_eq!(
                moved_rows(&after, table),
                moved_rows(&before, table),
                "{case}: {table}"
            );
        }
    }
}

/// The confirmation that offers to switch the package checks on counts the
/// work already waiting in the project, and lists the files the setup
/// writes. A catalog that moved since the install is no such work: the
/// render that follows the yes holds it at the record.
#[test]
#[allow(clippy::unwrap_used)]
fn the_package_check_confirmation_counts_no_moved_catalog_as_waiting() {
    let world = world();
    move_the_catalog(&world);
    let env = Env::host_rooted(&world.home);
    let scope = Scope::Project {
        root: world.project.clone(),
    };

    let waiting = kendex_core::drift::setup::pending_without_checks(&env, &scope).unwrap();
    let lines: Vec<String> = waiting.plan.ops.iter().map(|op| op.line()).collect();
    assert!(lines.is_empty(), "{lines:?}");

    let setup = kendex_core::drift::setup::setup_plan(&env, &scope).unwrap();
    assert_eq!(setup.other_pending, 0);
    // A skill's row names its directory, the tree the render writes.
    let listed: BTreeSet<&str> = setup.files.iter().map(|file| file.path.as_str()).collect();
    for render in MOVED_RENDERS {
        let under = listed
            .iter()
            .find(|path| render == *path || render.starts_with(&format!("{path}/")));
        assert_eq!(under, None, "{render} in {listed:?}");
    }
}
