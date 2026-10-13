//! The source reader owns the catalog minimum. Planning must refuse a
//! whole mixed-source scope before producing an install plan.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;
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
