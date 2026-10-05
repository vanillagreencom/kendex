//! A declaration naming a hook the catalog retired is skipped with a
//! warning carrying the manifest edit, and the copies it installed come
//! out in the sweep; every other name the catalog does not carry keeps the
//! refusal that fails a refresh, so a retired name cannot hide a typo.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::PathBuf;

use kendex_core::apply::{self, Op};
use kendex_core::engine::{DeclarationStatus, EngineReport, PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};

const HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: NAME\n# event: Stop\n# matcher:\n# description: hold the turn\n# ---\nexit 0\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    script: PathBuf,
    catalog_copy: PathBuf,
}

/// A project that declares `[hooks.<name>]` from a catalog carrying it,
/// with the hook installed.
#[allow(clippy::unwrap_used)]
fn installed(name: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let source = home.join("catalog");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let catalog_copy = source.join("hooks").join(format!("{name}.sh"));
    fs::write(&catalog_copy, HOOK.replace("NAME", name)).unwrap();
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[hooks.{name}]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = audit(&env, &scope).unwrap();
    apply::execute(&env, &report.plan).unwrap();
    let script = project.join(".claude/hooks").join(format!("{name}.sh"));
    assert!(script.is_file(), "the fixture installs the hook first");
    Fixture {
        _tmp: tmp,
        env,
        scope,
        script,
        catalog_copy,
    }
}

/// Refresh's plan: the sweep on, orphan removal off.
fn refresh_options() -> PlanOptions {
    PlanOptions {
        sweep_unneeded: true,
        ..PlanOptions::default()
    }
}

/// The note `refresh_failures` in the CLI's `engine_common.rs` turns into
/// a failed refresh; this is its machine-read spelling. Only the key of
/// each such note comes back: a failure message prints these, and a note
/// may quote plan material.
fn not_found_keys(report: &EngineReport) -> Vec<String> {
    report
        .notes
        .iter()
        .filter(|note| note.contains("not found in source"))
        .map(|note| note.split(':').next().unwrap_or_default().to_owned())
        .collect()
}

/// The names of the hook warnings, the view a failure message prints.
fn hook_warning_names(report: &EngineReport) -> Vec<String> {
    report
        .warnings
        .iter()
        .filter(|w| w.kind == ItemKind::Hook)
        .map(|w| w.name.clone())
        .collect()
}

/// The paths the plan trashes, the view a failure message prints.
fn trash_paths(report: &EngineReport) -> Vec<PathBuf> {
    report
        .plan
        .ops
        .iter()
        .filter_map(|op| match &op.op {
            Op::Trash { path, .. } => Some(path.clone()),
            _ => None,
        })
        .collect()
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_retired_hook_still_declared_is_skipped_with_one_warning_and_swept() {
    let f = installed("doc-drift-check");
    fs::remove_file(&f.catalog_copy).unwrap();

    let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();

    assert_eq!(report.declaration_status, DeclarationStatus::Complete);
    assert_eq!(not_found_keys(&report), Vec::<String>::new());
    assert_eq!(hook_warning_names(&report), ["doc-drift-check"]);
    let retired = report
        .warnings
        .iter()
        .find(|w| w.kind == ItemKind::Hook && w.name == "doc-drift-check")
        .unwrap();
    assert_eq!(retired.harness, None);
    // The line the consumer refresh report (KEN-2797) forwards from a
    // `kendex refresh` capture: the hook name, a colon, one space.
    assert!(
        retired.message.starts_with("doc-drift-check: "),
        "the warning message is not keyed by the hook name"
    );
    let trashed = trash_paths(&report);
    assert!(trashed.contains(&f.script), "trashed: {trashed:?}");
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!f.script.exists(), "the stranded copy comes out");
}

/// The must-fail control: a hook name that is merely absent keeps the
/// refusal, and its installed copy stays where a refusal keeps it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unknown_hook_name_keeps_the_refusal() {
    let f = installed("other-check");
    fs::remove_file(&f.catalog_copy).unwrap();

    let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();

    assert_eq!(report.declaration_status, DeclarationStatus::Incomplete);
    assert_eq!(not_found_keys(&report), ["other-check"]);
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.starts_with("other-check: not found in source 'cat'")),
        "the refusal note does not open with the hook name and the source"
    );
    assert_eq!(hook_warning_names(&report), Vec::<String>::new());
    let trashed = trash_paths(&report);
    assert!(!trashed.contains(&f.script), "trashed: {trashed:?}");
}
