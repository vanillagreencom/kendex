//! Switching one package or one source on or off, and removing a source,
//! change what the verb names and hold every other package at the commit
//! its lock entry records, as `kendex remove` does. A catalog that moved on
//! since the install is not brought current by any of them, and a package
//! one of them switches keeps what it requires where the record placed it.
//!
//! The fixture is `remove_locked`'s: `verify_records`'s consumer with the
//! catalog moved past the install by `refresh_locked`'s commit. A row that
//! switches something back on switches it off and commits first, while the
//! catalog still sits at the install. The control is the plan these verbs
//! made before this held them: planned at the catalog's tip, each rewrote
//! the moved skill, agent and command beside what it named.
//!
//! A held package whose recorded commit this machine cannot read resolves
//! at the catalog's tip instead: the catalog's history rewritten past the
//! install, read by a machine whose mirror never fetched the old commit.
//! Held there, every package was skipped, the switched one stayed as it
//! was behind a manifest that said otherwise, and the generated-paths
//! inventory dropped the renders of every package skipped.
//! A commit this machine has merely not fetched yet, the record a teammate
//! committed against a newer catalog, is fetched and held: read fresh
//! against the stale mirror, every package moved back to the older commit.
#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs;

use kendex_core::env::Env;
use kendex_core::model::{ItemKind, Scope};

use super::refresh_locked::{changed, move_the_catalog, record};
use super::verify_records::{World, commit, git, kendex, said, world, write};

/// How a row switches its subject: by a CLI verb, or by the app's toggle,
/// which calls the engine with one name and its kind.
enum Verb {
    Cli(&'static [&'static str]),
    App { enabled: bool },
}

/// What the verb names, and so which records it may change.
enum Subject {
    /// A package: its own lock entries.
    Package {
        kind: &'static str,
        name: &'static str,
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
    /// Moved and recorded there by a teammate, while this machine's mirror
    /// stops at the install: the record names a commit upstream still holds.
    Behind,
    /// Out of reach, with no cache on this machine: a fresh clone of the
    /// project, offline or denied the catalog.
    Unreachable,
}

struct Row {
    case: &'static str,
    /// Run on the installed world, then committed, before `setup`.
    prepare: Option<fn(&World)>,
    /// Run and committed before the catalog moves.
    setup: Option<&'static [&'static str]>,
    catalog: Catalog,
    verb: Verb,
    subject: Subject,
    /// What every lock entry of a package the subject names says after the
    /// verb; `None` where it names none.
    enabled: Option<bool>,
    /// A package the subject requires and nothing declares: it switches with
    /// the subject, and nothing else about its record moves.
    requirement: Option<&'static str>,
    changed: &'static [&'static str],
    /// Unchanged paths that leave the generated-paths inventory: only a
    /// switched-off source's renders, which stay on disk unmanaged.
    delisted: &'static [&'static str],
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
};

const DISABLE_GUARD: &[&str] = &["disable", "guard", "--scope", "project", "-y", "--leave"];
const ENABLE_GUARD: &[&str] = &["enable", "guard", "--scope", "project", "-y", "--leave"];

const ROWS: &[Row] = &[
    Row {
        case: "kendex disable",
        prepare: None,
        setup: None,
        catalog: Catalog::Moved,
        verb: Verb::Cli(DISABLE_GUARD),
        subject: GUARD,
        enabled: Some(false),
        requirement: None,
        changed: HOOK_PATHS,
        delisted: &[],
    },
    Row {
        case: "kendex enable",
        prepare: None,
        setup: Some(DISABLE_GUARD),
        catalog: Catalog::Moved,
        verb: Verb::Cli(ENABLE_GUARD),
        subject: GUARD,
        enabled: Some(true),
        requirement: None,
        changed: HOOK_PATHS,
        delisted: &[],
    },
    Row {
        case: "app toggle",
        prepare: None,
        setup: None,
        catalog: Catalog::Moved,
        verb: Verb::App { enabled: false },
        subject: GUARD,
        enabled: Some(false),
        requirement: None,
        changed: HOOK_PATHS,
        delisted: &[],
    },
    Row {
        case: "kendex disable, a requirement nothing declares",
        prepare: Some(require_a_helper),
        setup: None,
        catalog: Catalog::Moved,
        verb: Verb::Cli(&["disable", "lead", "--scope", "project", "-y", "--leave"]),
        subject: Subject::Package {
            kind: "skill",
            name: "lead",
        },
        enabled: Some(false),
        requirement: Some("helper"),
        changed: &[
            "kendex.toml",
            ".kendex-lock.json",
            ".kendex-generated.json",
            ".claude/skills/lead/SKILL.md",
            ".claude/skills/lead/SKILL.md.disabled",
            ".claude/skills/helper/SKILL.md",
            ".claude/skills/helper/SKILL.md.disabled",
        ],
        delisted: &[],
    },
    Row {
        case: "kendex source remove",
        prepare: None,
        setup: None,
        catalog: Catalog::Moved,
        verb: Verb::Cli(&["source", "remove", "spare", "--leave"]),
        subject: Subject::Source("spare"),
        enabled: None,
        requirement: None,
        changed: SOURCE_PATHS,
        delisted: &[],
    },
    Row {
        case: "kendex source disable",
        prepare: None,
        setup: None,
        catalog: Catalog::Moved,
        verb: Verb::Cli(&["source", "disable", "spare", "--leave"]),
        subject: Subject::Source("spare"),
        enabled: None,
        requirement: None,
        changed: SOURCE_PATHS,
        delisted: &[],
    },
    Row {
        case: "kendex source enable",
        prepare: None,
        setup: Some(&["source", "disable", "spare", "--leave"]),
        catalog: Catalog::Moved,
        verb: Verb::Cli(&["source", "enable", "spare", "--leave"]),
        subject: Subject::Source("spare"),
        enabled: None,
        requirement: None,
        changed: SOURCE_PATHS,
        delisted: &[],
    },
    Row {
        case: "kendex disable, record ahead of the mirror",
        prepare: None,
        setup: None,
        catalog: Catalog::Behind,
        verb: Verb::Cli(DISABLE_GUARD),
        subject: GUARD,
        enabled: Some(false),
        requirement: None,
        changed: HOOK_PATHS,
        delisted: &[],
    },
    Row {
        case: "kendex source disable, catalog unreachable",
        prepare: Some(switch_off_picat),
        setup: None,
        catalog: Catalog::Unreachable,
        verb: Verb::Cli(&["source", "disable", "cat", "--leave"]),
        subject: Subject::Source("cat"),
        enabled: None,
        requirement: None,
        changed: &["kendex.toml", ".kendex-lock.json", ".kendex-generated.json"],
        delisted: &[
            ".agents/skills/second/SKILL.md",
            ".agents/skills/second__command/SKILL.md",
            ".claude/agents/review.md",
            ".claude/hooks/guard.sh",
            ".claude/skills/second/SKILL.md",
            ".mcp.json",
        ],
    },
    Row {
        case: "kendex disable, a switched-off source unreachable",
        prepare: Some(switch_off_cat_and_picat),
        setup: None,
        catalog: Catalog::Unreachable,
        verb: Verb::Cli(&[
            "disable",
            "data-science/eda",
            "--scope",
            "project",
            "-y",
            "--leave",
        ]),
        subject: Subject::Package {
            kind: "skill",
            name: "data-science/eda",
        },
        enabled: Some(false),
        requirement: None,
        changed: &[
            "kendex.toml",
            ".kendex-lock.json",
            ".kendex-generated.json",
            ".claude/skills/data-science__eda/SKILL.md",
            ".claude/skills/data-science__eda/SKILL.md.disabled",
            ".opencode/skills/data-science-eda/SKILL.md",
            ".opencode/skills/data-science-eda/SKILL.md.disabled",
        ],
        delisted: &[],
    },
    Row {
        case: "kendex disable, recorded commit gone",
        prepare: None,
        setup: None,
        catalog: Catalog::Rewritten,
        verb: Verb::Cli(DISABLE_GUARD),
        subject: GUARD,
        enabled: Some(false),
        requirement: None,
        changed: HOOK_PATHS,
        delisted: &[],
    },
    Row {
        case: "kendex enable, recorded commit gone",
        prepare: None,
        setup: Some(DISABLE_GUARD),
        catalog: Catalog::Rewritten,
        verb: Verb::Cli(ENABLE_GUARD),
        subject: GUARD,
        enabled: Some(true),
        requirement: None,
        changed: HOOK_PATHS,
        delisted: &[],
    },
    Row {
        case: "app toggle, recorded commit gone",
        prepare: None,
        setup: None,
        catalog: Catalog::Rewritten,
        verb: Verb::App { enabled: false },
        subject: GUARD,
        enabled: Some(false),
        requirement: None,
        changed: HOOK_PATHS,
        delisted: &[],
    },
    Row {
        case: "kendex source enable, recorded commit gone",
        prepare: None,
        setup: Some(&["source", "disable", "cat", "--leave"]),
        catalog: Catalog::Rewritten,
        verb: Verb::Cli(&["source", "enable", "cat", "--leave"]),
        subject: Subject::Source("cat"),
        enabled: Some(true),
        requirement: None,
        changed: &["kendex.toml", ".kendex-lock.json", ".kendex-generated.json"],
        delisted: &[],
    },
];

/// A skill `lead` declared from the catalog, requiring `helper`, which
/// nothing declares, so `helper` reads at whatever commit `lead` reads.
/// `helper` changes in the catalog's later commit.
#[allow(clippy::unwrap_used)]
fn require_a_helper(world: &World) {
    write(
        &world.catalog.join("skills/lead/SKILL.md"),
        "---\nname: lead\ndescription: leads\ndependencies:\n  required: [helper]\n---\n# Lead\n",
    );
    write(
        &world.catalog.join("skills/helper/SKILL.md"),
        "---\nname: helper\ndescription: helps\n---\n# Helper\n",
    );
    commit(&world.catalog, "a skill and what it requires");
    let manifest = world.project.join("kendex.toml");
    let declared = fs::read_to_string(&manifest).unwrap();
    write(
        &manifest,
        &format!("{declared}\n[skills.lead]\nsource = \"cat\"\nharnesses = [\"claude\"]\n"),
    );
    for args in [
        &["source", "refresh"][..],
        &["apply", "--scope", "project", "-y", "--leave"],
    ] {
        let output = kendex(&world.home, &world.project, args);
        assert!(
            output.status.success(),
            "kendex {args:?}: {}",
            said(&output)
        );
    }
    let helper = world.catalog.join("skills/helper/SKILL.md");
    let before = fs::read_to_string(&helper).unwrap();
    write(&helper, &format!("{before}\nHelps more now.\n"));
}

/// A teammate brings the catalog current and commits the record there,
/// while this machine's mirror is cloned again from the catalog as it stood
/// at the install: the record names a commit upstream holds and this
/// machine never fetched.
#[allow(clippy::unwrap_used)]
fn fall_behind(world: &World) {
    move_the_catalog(world);
    let applied = kendex(
        &world.home,
        &world.project,
        &["apply", "--scope", "project", "-y", "--leave"],
    );
    assert!(applied.status.success(), "{}", said(&applied));
    commit(&world.project, "a teammate brings the catalog current");
    let ahead = git(&world.catalog, &["rev-parse", "HEAD"]);
    git(&world.catalog, &["reset", "-q", "--hard", "HEAD~1"]);
    let cache = Env::host_rooted(&world.home).source_cache_dir();
    fs::remove_dir_all(&cache).unwrap_or_else(|error| panic!("{}: {error}", cache.display()));
    let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
    assert!(fetched.status.success(), "{}", said(&fetched));
    git(&world.catalog, &["reset", "-q", "--hard", ahead.trim()]);
}

/// The source only the Pi package reads from, switched off.
fn switch_off_picat(world: &World) {
    let output = kendex(
        &world.home,
        &world.project,
        &["source", "disable", "picat", "--leave"],
    );
    assert!(output.status.success(), "{}", said(&output));
}

/// Every source the catalog's repository is read under for a package,
/// switched off.
fn switch_off_cat_and_picat(world: &World) {
    switch_off_picat(world);
    let output = kendex(
        &world.home,
        &world.project,
        &["source", "disable", "cat", "--leave"],
    );
    assert!(output.status.success(), "{}", said(&output));
}

/// The catalog moved out of reach and this machine's source cache gone.
fn lose_the_catalog(world: &World) {
    let away = world.catalog.with_file_name("cat-unreachable");
    fs::rename(&world.catalog, &away).unwrap_or_else(|error| panic!("{}: {error}", away.display()));
    let cache = Env::host_rooted(&world.home).source_cache_dir();
    fs::remove_dir_all(&cache).unwrap_or_else(|error| panic!("{}: {error}", cache.display()));
}

/// The catalog's history rewritten so the installed commit is gone from
/// it, and the source cache cleared so the mirror is fetched fresh from
/// the rewritten history, as a second machine reading the committed
/// record fetches it.
pub(crate) fn rewrite_the_catalog(world: &World) {
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
            (Subject::Package { kind, name }, "entries") => {
                value["kind"] == *kind && value["name"] == *name
            }
            (Subject::Package { .. }, _) => false,
            (Subject::Source(source), "sources") => key == *source,
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

/// The paths `.kendex-generated.json` lists.
#[allow(clippy::unwrap_used)]
pub(crate) fn listed(world: &World) -> BTreeSet<String> {
    serde_json::from_str(&fs::read_to_string(world.project.join(".kendex-generated.json")).unwrap())
        .unwrap()
}

/// Runs the row's verb, with what it printed.
#[allow(clippy::unwrap_used)]
fn run(world: &World, verb: &Verb, case: &str) -> String {
    match *verb {
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
    }
}

/// The record the verb should leave beside what its subject owns. Where
/// the recorded commit is gone, every package reads at the catalog's
/// current commit, and the record otherwise reads as it did with that
/// commit put in place of the gone one, except the records of the sources
/// no package read this pass, which the locked plan keeps as written.
#[allow(clippy::unwrap_used)]
fn expected_record(
    world: &World,
    row: &Row,
    before: serde_json::Value,
    after: &serde_json::Value,
) -> serde_json::Value {
    match row.catalog {
        Catalog::Moved | Catalog::Behind | Catalog::Unreachable => before,
        Catalog::Rewritten => {
            let installed = &before["entries"]["hook:guard:claude"];
            let gone = installed["sourceCommit"].as_str().unwrap();
            let head = git(&world.catalog, &["rev-parse", "HEAD"]);
            let head = head.trim();
            for (key, entry) in after["entries"].as_object().unwrap() {
                if entry["sourceRepo"] == installed["sourceRepo"] {
                    assert_eq!(entry["sourceCommit"], head, "{}: {key}", row.case);
                }
            }
            let mut expected: serde_json::Value =
                serde_json::from_str(&before.to_string().replace(gone, head)).unwrap();
            for unread in ["picat", "spare"] {
                expected["sources"][unread] = before["sources"][unread].clone();
            }
            expected
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_toggle_or_source_change_holds_every_other_package_at_its_recorded_commit() {
    for row in ROWS {
        let case = row.case;
        let world = world();
        if let Some(prepare) = row.prepare {
            prepare(&world);
            commit(&world.project, "prepared");
        }
        if let Some(setup) = row.setup {
            let output = kendex(&world.home, &world.project, setup);
            assert!(output.status.success(), "{case}: {}", said(&output));
            commit(&world.project, "switched off before the catalog moves");
        }
        match row.catalog {
            Catalog::Moved => move_the_catalog(&world),
            Catalog::Rewritten => rewrite_the_catalog(&world),
            Catalog::Behind => fall_behind(&world),
            Catalog::Unreachable => lose_the_catalog(&world),
        }
        let before = record(&world);
        let before_listed = listed(&world);

        let said = run(&world, &row.verb, case);

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
        let after_listed = listed(&world);
        let unlisted: BTreeSet<&str> = before_listed
            .difference(&after_listed)
            .map(String::as_str)
            .filter(|path| !row.changed.contains(path))
            .collect();
        assert_eq!(
            unlisted,
            row.delisted.iter().copied().collect(),
            "{case}: de-listed"
        );

        let mut expected = expected_record(&world, row, before, &after);
        // The requirement switches with its parent, which renames what it
        // renders; where it reads from and what it read stay put.
        let mut after = after;
        if let Some(requirement) = row.requirement {
            for record in [&mut after, &mut expected] {
                for entry in record["entries"].as_object_mut().unwrap().values_mut() {
                    if entry["name"] == requirement {
                        let entry = entry.as_object_mut().unwrap();
                        entry.remove("enabled");
                        entry.remove("renderedHash");
                    }
                }
            }
        }
        for table in ["entries", "sources", "bundles"] {
            assert_eq!(
                rows_of(&after, table, &row.subject, false),
                rows_of(&expected, table, &row.subject, false),
                "{case}: {table}"
            );
        }
    }
}
