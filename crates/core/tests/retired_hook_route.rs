//! A declaration naming a retired hook is skipped with a warning carrying
//! the manifest edit, whether or not the catalog still carries the hook,
//! and the copies an earlier release installed come out in the sweep;
//! every other name the catalog does not carry keeps the refusal that
//! fails a refresh, so a retired name cannot hide a typo.
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
    project: PathBuf,
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
        project,
        script,
        catalog_copy,
    }
}

/// A project an earlier release installed the retired hook `name` into,
/// from a catalog that carried it. This release installs no retired hook,
/// so the fixture installs a stand-in and renames it to `name` in every
/// file the install wrote.
#[allow(clippy::unwrap_used)]
fn installed_by_an_earlier_release(name: &str) -> Fixture {
    const STAND_IN: &str = "stand-in-check";
    let mut f = installed(STAND_IN);
    for file in [
        f.project.join("kendex.toml"),
        f.project.join(".kendex-lock.json"),
        f.project.join(".claude/settings.json"),
    ] {
        let text = fs::read_to_string(&file).unwrap();
        assert!(
            text.contains(STAND_IN),
            "{} names no stand-in",
            file.display()
        );
        fs::write(&file, text.replace(STAND_IN, name)).unwrap();
    }
    let script = f.script.with_file_name(format!("{name}.sh"));
    fs::rename(&f.script, &script).unwrap();
    let catalog_copy = f.catalog_copy.with_file_name(format!("{name}.sh"));
    fs::rename(&f.catalog_copy, &catalog_copy).unwrap();
    f.script = script;
    f.catalog_copy = catalog_copy;
    f
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

/// The paths a plan op other than a trash writes whose file name opens with
/// `name`, the view a failure message prints.
fn written_hook_files(report: &EngineReport, name: &str) -> Vec<PathBuf> {
    report
        .plan
        .ops
        .iter()
        .filter(|op| !matches!(op.op, Op::Trash { .. }))
        .flat_map(|op| op.op.touched())
        .filter(|path| {
            path.file_name()
                .is_some_and(|file| file.to_string_lossy().starts_with(name))
        })
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

/// One row per catalog state: the retired hook removed, and the hook still
/// carried, as the KEN-2967 stub is.
#[test]
#[allow(clippy::unwrap_used)]
fn a_retired_hook_still_declared_is_skipped_with_one_warning_and_swept() {
    for catalog_carries_it in [false, true] {
        let f = installed_by_an_earlier_release("doc-drift-check");
        if !catalog_carries_it {
            fs::remove_file(&f.catalog_copy).unwrap();
        }

        let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();

        let row = format!("catalog carries it: {catalog_carries_it}");
        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Complete,
            "{row}"
        );
        assert_eq!(not_found_keys(&report), Vec::<String>::new(), "{row}");
        assert_eq!(hook_warning_names(&report), ["doc-drift-check"], "{row}");
        let retired = report
            .warnings
            .iter()
            .find(|w| w.kind == ItemKind::Hook && w.name == "doc-drift-check")
            .unwrap();
        assert_eq!(retired.harness, None, "{row}");
        // The line the consumer refresh report (KEN-2797) forwards from a
        // `kendex refresh` capture: the hook name, a colon, one space.
        assert!(
            retired.message.starts_with("doc-drift-check: "),
            "{row}: the warning message is not keyed by the hook name"
        );
        let written = written_hook_files(&report, "doc-drift-check");
        assert_eq!(written, Vec::<PathBuf>::new(), "{row}");
        let trashed = trash_paths(&report);
        assert!(trashed.contains(&f.script), "{row}: trashed: {trashed:?}");
        apply::execute(&f.env, &report.plan).unwrap();
        assert!(!f.script.exists(), "{row}: the stranded copy comes out");
    }
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
