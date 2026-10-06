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
#![cfg(unix)]

use std::collections::BTreeSet;

use kendex_core::env::Env;
use kendex_core::model::{ItemKind, Scope};

use super::refresh_locked::{changed, move_the_catalog, record};
use super::verify_records::{commit, kendex, said, world};

/// How a row switches its subject: by a CLI verb, or by the app's toggle,
/// which calls the engine with one name and its kind.
enum Verb {
    Cli(&'static [&'static str]),
    App { enabled: bool },
}

struct Row {
    case: &'static str,
    /// Run and committed before the catalog moves.
    setup: Option<&'static [&'static str]>,
    verb: Verb,
    /// The lock entry the verb is allowed to change, by kind and name.
    package: Option<(&'static str, &'static str)>,
    /// The source record the verb is allowed to change.
    source: Option<&'static str>,
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

fn rows() -> Vec<Row> {
    vec![
        Row {
            case: "kendex disable",
            setup: None,
            verb: Verb::Cli(&["disable", "guard", "--scope", "project", "-y", "--leave"]),
            package: Some(("hook", "guard")),
            source: None,
            changed: HOOK_PATHS,
        },
        Row {
            case: "kendex enable",
            setup: Some(&["disable", "guard", "--scope", "project", "-y", "--leave"]),
            verb: Verb::Cli(&["enable", "guard", "--scope", "project", "-y", "--leave"]),
            package: Some(("hook", "guard")),
            source: None,
            changed: HOOK_PATHS,
        },
        Row {
            case: "app toggle",
            setup: None,
            verb: Verb::App { enabled: false },
            package: Some(("hook", "guard")),
            source: None,
            changed: HOOK_PATHS,
        },
        Row {
            case: "kendex source remove",
            setup: None,
            verb: Verb::Cli(&["source", "remove", "spare", "--leave"]),
            package: None,
            source: Some("spare"),
            changed: SOURCE_PATHS,
        },
        Row {
            case: "kendex source disable",
            setup: None,
            verb: Verb::Cli(&["source", "disable", "spare", "--leave"]),
            package: None,
            source: Some("spare"),
            changed: SOURCE_PATHS,
        },
        Row {
            case: "kendex source enable",
            setup: Some(&["source", "disable", "spare", "--leave"]),
            verb: Verb::Cli(&["source", "enable", "spare", "--leave"]),
            package: None,
            source: Some("spare"),
            changed: SOURCE_PATHS,
        },
    ]
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
        move_the_catalog(&world);
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
        assert_eq!(after["bundles"], before["bundles"], "{case}");
        let sources = |record: &serde_json::Value| {
            let mut sources = record["sources"].as_object().unwrap().clone();
            if let Some(source) = row.source {
                sources.remove(source);
            }
            sources
        };
        assert_eq!(sources(&after), sources(&before), "{case}");
        let others = |record: &serde_json::Value| {
            record["entries"]
                .as_object()
                .unwrap()
                .iter()
                .filter(|(_, entry)| {
                    row.package.is_none_or(|(kind, name)| {
                        !(entry["kind"] == kind && entry["name"] == name)
                    })
                })
                .map(|(key, entry)| (key.clone(), entry.clone()))
                .collect::<Vec<_>>()
        };
        assert_eq!(others(&after), others(&before), "{case}");
    }
}
