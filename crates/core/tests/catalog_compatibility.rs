//! The source reader owns the catalog minimum. Planning must refuse a
//! whole mixed-source scope before producing an install plan.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::ops;
use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::source::{CatalogMinReason, source_config};
use kendex_core::source_read::SealedSource;

use crate::test_util::{rooted, source_path};

const FUTURE: &str = "999999.0.0";

enum Verdict {
    Compatible,
    NeedsEngine,
    Invalid(CatalogMinReason, &'static str),
}

#[test]
#[allow(clippy::unwrap_used, clippy::too_many_lines)]
fn catalog_minimum_table() {
    let current = format!("min_kendex = {:?}", env!("CARGO_PKG_VERSION"));
    let build_metadata = format!(
        "min_kendex = '{}+catalog'",
        env!("CARGO_PKG_VERSION").split('+').next().unwrap()
    );
    let rows = [
        ("absent", "", Verdict::Compatible),
        ("equal", current.as_str(), Verdict::Compatible),
        (
            "build metadata",
            build_metadata.as_str(),
            Verdict::Compatible,
        ),
        ("older", "min_kendex = '0.0.0'", Verdict::Compatible),
        ("newer", "min_kendex = '999999.0.0'", Verdict::NeedsEngine),
        (
            "misspelled",
            "min-kendex = '999999.0.0'",
            Verdict::Compatible,
        ),
        (
            "nested",
            "[catalog]\nmin_kendex = '999999.0.0'",
            Verdict::Compatible,
        ),
        (
            "boolean",
            "min_kendex = true",
            Verdict::Invalid(CatalogMinReason::ExpectedString, "boolean"),
        ),
        (
            "integer",
            "min_kendex = 1",
            Verdict::Invalid(CatalogMinReason::ExpectedString, "integer"),
        ),
        (
            "float",
            "min_kendex = 1.0",
            Verdict::Invalid(CatalogMinReason::ExpectedString, "float"),
        ),
        (
            "datetime",
            "min_kendex = 2026-10-13",
            Verdict::Invalid(CatalogMinReason::ExpectedString, "datetime"),
        ),
        (
            "array",
            "min_kendex = ['1.0.0']",
            Verdict::Invalid(CatalogMinReason::ExpectedString, "array"),
        ),
        (
            "table",
            "min_kendex = { version = '1.0.0' }",
            Verdict::Invalid(CatalogMinReason::ExpectedString, "table"),
        ),
        (
            "empty",
            "min_kendex = ''",
            Verdict::Invalid(CatalogMinReason::InvalidSemver, ""),
        ),
        (
            "incomplete",
            "min_kendex = '1.0'",
            Verdict::Invalid(CatalogMinReason::InvalidSemver, "1.0"),
        ),
        (
            "range",
            "min_kendex = '>=1.0.0'",
            Verdict::Invalid(CatalogMinReason::InvalidSemver, ">=1.0.0"),
        ),
        (
            "leading zero",
            "min_kendex = '01.0.0'",
            Verdict::Invalid(CatalogMinReason::InvalidSemver, "01.0.0"),
        ),
        (
            "untrusted text",
            "min_kendex = \"bad\\nvalue engine=forged\"",
            Verdict::Invalid(CatalogMinReason::InvalidSemver, "bad\nvalue engine=forged"),
        ),
    ];
    for (case, text, verdict) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        fs::write(root.join("kendex.toml"), text).unwrap();
        let result = source_config(&SealedSource::open(&root).unwrap(), "fixture");
        match verdict {
            Verdict::Compatible => assert!(result.is_ok(), "{case}: {result:?}"),
            Verdict::NeedsEngine => assert!(
                matches!(result,
                Err(CoreError::CatalogNeedsEngine { ref min, engine })
                    if min == FUTURE && engine == env!("CARGO_PKG_VERSION")),
                "{case}: {result:?}"
            ),
            Verdict::Invalid(expected_reason, expected_min) => assert!(
                matches!(result,
                Err(CoreError::CatalogMinInvalid { ref min, engine, reason })
                    if min == expected_min && engine == env!("CARGO_PKG_VERSION") && reason == expected_reason),
                "{case}: {result:?}"
            ),
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn compatible_minima_render_the_same_bytes_and_newer_minima_write_nothing() {
    for min in [
        None,
        Some("0.0.0"),
        Some(env!("CARGO_PKG_VERSION")),
        Some(FUTURE),
    ] {
        for bundle in [false, true] {
            let tmp = tempfile::tempdir().unwrap();
            let home = rooted(&tmp);
            let env = Env::fake(&home, FakeOs::Linux);
            let project = home.join("consumer");
            fs::create_dir_all(project.join(".claude")).unwrap();
            let mut sources = String::new();
            for (name, minimum) in [("good", None), ("gated", min)] {
                let catalog = home.join(name);
                fs::create_dir_all(catalog.join(format!("skills/{name}"))).unwrap();
                fs::write(
                    catalog.join(format!("skills/{name}/SKILL.md")),
                    format!("---\nname: {name}\ndescription: fixture\n---\nBody.\n"),
                )
                .unwrap();
                let key = minimum
                    .map(|min| format!("min_kendex = {min:?}\n"))
                    .unwrap_or_default();
                fs::write(
                    catalog.join("kendex.toml"),
                    format!("{key}[bundles.starter]\nskills = ['{name}']\n"),
                )
                .unwrap();
                sources.push_str(&format!("[sources.{name}]\n{}\n", source_path(&catalog)));
            }
            let gated = if bundle {
                "[bundles.starter]"
            } else {
                "[skills.gated]"
            };
            let declared = format!(
                "schema = 7\n{sources}[install]\nharnesses = ['claude']\nmethod = 'copy'\n[skills.good]\nsource = 'good'\n{gated}\nsource = 'gated'\n"
            );
            fs::write(project.join("kendex.toml"), &declared).unwrap();
            let scope = Scope::Project {
                root: project.clone(),
            };
            let result = plan_apply(&env, &scope, &PlanOptions::current());
            if min == Some(FUTURE) {
                assert!(
                    matches!(result, Err(CoreError::CatalogNeedsEngine { ref min, .. }) if min == FUTURE),
                    "{result:?}"
                );
                assert_eq!(
                    fs::read_to_string(project.join("kendex.toml")).unwrap(),
                    declared
                );
                let mut entries: Vec<_> = fs::read_dir(&project)
                    .unwrap()
                    .map(|entry| entry.unwrap().file_name())
                    .collect();
                entries.sort();
                assert_eq!(entries, [".claude", "kendex.toml"]);
                assert!(
                    fs::read_dir(project.join(".claude"))
                        .unwrap()
                        .next()
                        .is_none()
                );
            } else {
                let report = result.unwrap();
                apply::execute(&env, &report.plan).unwrap();
                for name in ["good", "gated"] {
                    assert_eq!(
                        fs::read(project.join(format!(".claude/skills/{name}/SKILL.md"))).unwrap(),
                        fs::read(home.join(format!("{name}/skills/{name}/SKILL.md"))).unwrap()
                    );
                }
            }
        }
    }
}

#[test]
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn minimum_refuses_before_the_plugin_registry_is_read() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    fs::write(
        root.join("kendex.toml"),
        format!("min_kendex = '{FUTURE}'\n"),
    )
    .unwrap();
    fs::create_dir(root.join(".claude-plugin")).unwrap();
    std::os::unix::fs::symlink(
        root.join("outside"),
        root.join(".claude-plugin/marketplace.json"),
    )
    .unwrap();
    assert!(matches!(
        source_config(&SealedSource::open(&root).unwrap(), "fixture"),
        Err(CoreError::CatalogNeedsEngine { .. })
    ));
}

enum RemovalAction {
    Remove(Option<ItemKind>, bool),
    Uninstall,
    AnswerSweep,
}

enum Historical {
    Skill,
    Agent,
    Bundle,
    Dependency,
}

struct RemovalRow {
    case: &'static str,
    declarations: &'static str,
    target: &'static str,
    action: RemovalAction,
    historical: Historical,
    retained: Option<&'static [(ItemKind, &'static str)]>,
    declarations_after: (bool, bool, bool),
}

/// Pre-gate readers can record an incompatible revision. The package
/// bytes below are identical at both commits, so changing its recorded
/// date represents that installation without weakening today's reader.
#[allow(clippy::unwrap_used)]
fn removal_world(row: &RemovalRow) -> (tempfile::TempDir, Env, Scope, std::path::PathBuf) {
    use crate::test_util::git;

    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let catalog = home.join("catalog");
    let project = home.join("consumer");
    fs::create_dir_all(project.join(".claude")).unwrap();
    for name in ["good", "gated", "leftover"] {
        fs::create_dir_all(catalog.join(format!("skills/{name}"))).unwrap();
        let dependencies = if name == "gated" && matches!(row.historical, Historical::Dependency) {
            "dependencies:\n  required: [leftover]\n"
        } else {
            ""
        };
        fs::write(
            catalog.join(format!("skills/{name}/SKILL.md")),
            format!("---\nname: {name}\ndescription: fixture\n{dependencies}---\nBody.\n"),
        )
        .unwrap();
    }
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/gated.md"),
        "---\nname: gated\ndescription: fixture\n---\nBody.\n",
    )
    .unwrap();
    let control = |min| format!("min_kendex = '{min}'\n[bundles.old]\nskills = ['gated']\n");
    fs::write(catalog.join("kendex.toml"), control(FUTURE)).unwrap();
    git(&catalog, &["init", "-q", "-b", "main"]);
    git(&catalog, &["add", "-A"]);
    git(&catalog, &["commit", "-q", "-m", "historical minimum"]);
    let historical = git(&catalog, &["rev-parse", "HEAD"]).trim().to_owned();
    fs::write(catalog.join("kendex.toml"), control("0.0.0")).unwrap();
    git(&catalog, &["add", "-A"]);
    git(&catalog, &["commit", "-q", "-m", "compatible tip"]);
    let repo = format!("file://{}", catalog.display());
    fs::write(project.join("kendex.toml"), format!(
        "schema = 7\n[sources.cat]\nrepo = '{repo}'\nrev = 'main'\n[install]\nharnesses = ['claude']\nmethod = 'copy'\n[skills.good]\nsource = 'cat'\n{}",
        row.declarations)).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let manifest = kendex_core::manifest::load_current(&project.join("kendex.toml"))
        .unwrap()
        .unwrap();
    kendex_core::remote::sync_sources(&env, &manifest).unwrap();
    let report = plan_apply(&env, &scope, &PlanOptions::current()).unwrap();
    apply::execute(&env, &report.plan).unwrap();
    kendex_core::remote::sync(&env, &repo, Some(&historical)).unwrap();
    let path = kendex_core::lock::lock_path(&env, &scope);
    let mut lock = kendex_core::lock::load(&path).unwrap();
    for entry in lock.entries.values_mut() {
        let held = match row.historical {
            Historical::Skill => entry.kind == ItemKind::Skill && entry.name == "gated",
            Historical::Agent => entry.kind == ItemKind::Agent && entry.name == "gated",
            Historical::Bundle => entry.reasons.iter().any(|reason| {
                matches!(reason,
                kendex_core::lock::Reason::MemberOf { bundle } if bundle.name == "old")
            }),
            Historical::Dependency => entry.name == "gated" || entry.name == "leftover",
        };
        if held {
            entry.source_commit = Some(historical.clone());
        }
    }
    if matches!(row.historical, Historical::Bundle) {
        lock.bundles.get_mut("old").unwrap().commit = historical;
    }
    kendex_core::lock::save(&path, &lock).unwrap();
    (tmp, env, scope, project)
}

const SKILL: &str = "[skills.gated]\nsource = 'cat'\n";
const BOTH: &str = "[skills.gated]\nsource = 'cat'\n[agents.gated]\nsource = 'cat'\n";
const BUNDLE: &str = "[bundles.old]\nsource = 'cat'\n";
const BUNDLE_SKILL: &str = "[bundles.old]\nsource = 'cat'\n[skills.gated]\nsource = 'cat'\n";
const REMOVAL_ROWS: &[RemovalRow] = &[
    RemovalRow {
        case: "remove incompatible item",
        declarations: SKILL,
        target: "gated",
        action: RemovalAction::Remove(None, false),
        historical: Historical::Skill,
        retained: Some(&[(ItemKind::Skill, "good")]),
        declarations_after: (false, false, false),
    },
    RemovalRow {
        case: "uninstall incompatible item",
        declarations: SKILL,
        target: "gated",
        action: RemovalAction::Uninstall,
        historical: Historical::Skill,
        retained: Some(&[(ItemKind::Skill, "good")]),
        declarations_after: (true, false, false),
    },
    RemovalRow {
        case: "kind-narrowed surviving agent refuses",
        declarations: BOTH,
        target: "gated",
        action: RemovalAction::Remove(Some(ItemKind::Skill), false),
        historical: Historical::Agent,
        retained: None,
        declarations_after: (false, true, false),
    },
    RemovalRow {
        case: "kind-narrowed incompatible agent leaves skill",
        declarations: BOTH,
        target: "gated",
        action: RemovalAction::Remove(Some(ItemKind::Agent), false),
        historical: Historical::Agent,
        retained: Some(&[(ItemKind::Skill, "good"), (ItemKind::Skill, "gated")]),
        declarations_after: (true, false, false),
    },
    RemovalRow {
        case: "incompatible bundle leaves",
        declarations: BUNDLE,
        target: "old",
        action: RemovalAction::Remove(None, false),
        historical: Historical::Bundle,
        retained: Some(&[(ItemKind::Skill, "good")]),
        declarations_after: (false, false, false),
    },
    RemovalRow {
        case: "asked-for bundle member survives and refuses",
        declarations: BUNDLE_SKILL,
        target: "old",
        action: RemovalAction::Remove(None, false),
        historical: Historical::Bundle,
        retained: None,
        declarations_after: (true, false, false),
    },
    RemovalRow {
        case: "surviving bundle refuses",
        declarations: BUNDLE_SKILL,
        target: "gated",
        action: RemovalAction::Remove(Some(ItemKind::Skill), false),
        historical: Historical::Bundle,
        retained: None,
        declarations_after: (false, false, true),
    },
    RemovalRow {
        case: "no sweep keeps orphan",
        declarations: SKILL,
        target: "gated",
        action: RemovalAction::Remove(None, false),
        historical: Historical::Dependency,
        retained: Some(&[(ItemKind::Skill, "good"), (ItemKind::Skill, "leftover")]),
        declarations_after: (false, false, false),
    },
    RemovalRow {
        case: "sweep removes orphan",
        declarations: SKILL,
        target: "gated",
        action: RemovalAction::Remove(None, true),
        historical: Historical::Dependency,
        retained: Some(&[(ItemKind::Skill, "good")]),
        declarations_after: (false, false, false),
    },
    RemovalRow {
        case: "sweep answer replans captured inputs",
        declarations: SKILL,
        target: "gated",
        action: RemovalAction::AnswerSweep,
        historical: Historical::Dependency,
        retained: Some(&[(ItemKind::Skill, "good")]),
        declarations_after: (false, false, false),
    },
    RemovalRow {
        case: "uninstall keeps orphan and declaration",
        declarations: SKILL,
        target: "gated",
        action: RemovalAction::Uninstall,
        historical: Historical::Dependency,
        retained: Some(&[(ItemKind::Skill, "good"), (ItemKind::Skill, "leftover")]),
        declarations_after: (true, false, false),
    },
    RemovalRow {
        case: "surviving skill refuses",
        declarations: SKILL,
        target: "good",
        action: RemovalAction::Remove(None, false),
        historical: Historical::Skill,
        retained: None,
        declarations_after: (true, false, false),
    },
];

#[test]
#[allow(clippy::unwrap_used)]
fn prepared_removal_checks_only_its_remaining_readings() {
    for row in REMOVAL_ROWS {
        let (_tmp, env, scope, project) = removal_world(row);
        let before = fs::read(project.join("kendex.toml")).unwrap();
        let good = project.join(".claude/skills/good/SKILL.md");
        let good_before = fs::read(&good).unwrap();
        let names = [row.target.to_owned()];
        let prepared = match row.action {
            RemovalAction::Remove(kind, sweep) => {
                ops::prepare_remove(&env, &scope, &names, kind, sweep)
            }
            RemovalAction::Uninstall => ops::prepare_uninstall(&env, &scope, &names),
            RemovalAction::AnswerSweep => ops::prepare_remove(&env, &scope, &names, None, false),
        }
        .unwrap();
        let verdict = prepared.check_catalog_compatibility(&env);
        let Some(expected) = row.retained else {
            assert!(
                matches!(verdict, Err(CoreError::CatalogNeedsEngine { ref min, engine }) if min == FUTURE && engine == env!("CARGO_PKG_VERSION")),
                "{}: {verdict:?}",
                row.case
            );
            assert_eq!(fs::read(project.join("kendex.toml")).unwrap(), before);
            assert_eq!(fs::read(&good).unwrap(), good_before);
            continue;
        };
        verdict.unwrap_or_else(|error| panic!("{}: {error}", row.case));
        let report = if matches!(row.action, RemovalAction::AnswerSweep) {
            let preview = prepared.plan(&env).unwrap();
            assert!(
                preview
                    .sweepable
                    .iter()
                    .any(|change| change.name == "leftover")
            );
            prepared.plan_sweeping(&env).unwrap()
        } else {
            prepared.plan(&env).unwrap()
        };
        apply::execute(&env, &report.plan).unwrap();
        let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&env, &scope)).unwrap();
        let actual: std::collections::BTreeSet<_> = lock
            .entries
            .values()
            .map(|entry| (entry.kind, entry.name.as_str()))
            .collect();
        assert_eq!(actual, expected.iter().copied().collect(), "{}", row.case);
        for (kind, name) in [
            (ItemKind::Skill, "gated"),
            (ItemKind::Skill, "leftover"),
            (ItemKind::Agent, "gated"),
        ] {
            let path = match kind {
                ItemKind::Skill => project.join(format!(".claude/skills/{name}/SKILL.md")),
                ItemKind::Agent => project.join(format!(".claude/agents/{name}.md")),
                ItemKind::Hook
                | ItemKind::Command
                | ItemKind::McpServer
                | ItemKind::Plugin
                | ItemKind::PiExtension
                | ItemKind::OutputStyle => unreachable!("fixture has only skills and agents"),
            };
            assert_eq!(
                path.is_file(),
                expected.contains(&(kind, name)),
                "{}",
                row.case
            );
        }
        let manifest = kendex_core::manifest::load_current(&project.join("kendex.toml"))
            .unwrap()
            .unwrap();
        assert_eq!(
            (
                manifest.skills.contains_key("gated"),
                manifest.agents.contains_key("gated"),
                manifest.bundles.contains_key("old")
            ),
            row.declarations_after,
            "{}",
            row.case
        );
        if matches!(row.action, RemovalAction::Uninstall) {
            assert_eq!(fs::read(project.join("kendex.toml")).unwrap(), before);
        }
        assert_eq!(fs::read(&good).unwrap(), good_before, "{}", row.case);
    }
}
