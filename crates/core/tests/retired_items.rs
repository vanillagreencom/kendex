//! An item its catalog retires (`[retired]` in the catalog's kendex.toml)
//! leaves nothing installed: a declaration still naming it is skipped with
//! one warning carrying the catalog's migration, whether or not the catalog
//! still carries the item, derives no companion its header requires, and
//! the copies an earlier refresh installed come out in the sweep, an
//! emptied Copilot registry with them; an item requiring it is withheld.
//! Every other name the catalog does not carry keeps the refusal that fails
//! a refresh, so a retirement cannot hide a typo. Refresh also takes what a
//! declaration deleted by hand left, except a copy the person edited.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::PathBuf;

use kendex_core::apply::{self, Op};
use kendex_core::engine::{
    DeclarationStatus, DriftCause, DriftState, EngineReport, PlanOptions, audit, plan_apply,
};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};

const HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: NAME\n# event: PreToolUse\n# matcher: Bash\n# description: hold the call\n# ---\nexit 0\n";

const SKILL: &str = "---\nname: NAME\ndescription: Ship it\n---\n\nSteps.\n";

const CATALOG: &str = "is_source_catalog = true\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

impl Fixture {
    /// Where the catalog keeps `name` of `kind`.
    fn catalog_copy(&self, kind: ItemKind, name: &str) -> PathBuf {
        match kind {
            ItemKind::Skill => self.source.join("skills").join(name),
            _ => self.source.join("hooks").join(format!("{name}.sh")),
        }
    }

    /// The files an install of `name` of `kind` writes on each tool.
    fn installed_copies(&self, kind: ItemKind, name: &str) -> Vec<PathBuf> {
        match kind {
            ItemKind::Skill => vec![self.project.join(".claude/skills").join(name)],
            _ => vec![
                self.project
                    .join(".claude/hooks")
                    .join(format!("{name}.sh")),
                self.project
                    .join(".github/hooks")
                    .join(format!("{name}.sh")),
                self.project
                    .join(".github/hooks")
                    .join(format!("{name}.json")),
            ],
        }
    }

    /// The catalog retires `name` of `kind` with `migration`.
    #[allow(clippy::unwrap_used)]
    fn retire(&self, kind: ItemKind, name: &str, migration: &str) {
        fs::write(
            self.source.join("kendex.toml"),
            format!(
                "{CATALOG}\n[retired.{}s]\n{name} = \"{migration}\"\n",
                kind.name()
            ),
        )
        .unwrap();
    }
}

/// A Claude Code and Copilot project that declares `name` of `kind` from a
/// catalog carrying it, with the item installed.
#[allow(clippy::unwrap_used)]
fn installed(kind: ItemKind, name: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(project.join(".github")).unwrap();
    let source = home.join("catalog");
    let f = Fixture {
        _tmp: tmp,
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        source,
    };
    write_item(&f, kind, name);
    fs::write(f.source.join("kendex.toml"), CATALOG).unwrap();
    fs::write(
        f.project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\", \"copilot\"]\nmethod = \"copy\"\n\n[{}s.{name}]\nsource = \"cat\"\n",
            source_path(&f.source),
            kind.name()
        ),
    )
    .unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    for copy in f.installed_copies(kind, name) {
        assert!(copy.exists(), "the fixture installs {}", copy.display());
    }
    f
}

#[allow(clippy::unwrap_used)]
fn write_item(f: &Fixture, kind: ItemKind, name: &str) {
    let copy = f.catalog_copy(kind, name);
    match kind {
        ItemKind::Skill => {
            fs::create_dir_all(&copy).unwrap();
            fs::write(copy.join("SKILL.md"), SKILL.replace("NAME", name)).unwrap();
        }
        _ => {
            fs::create_dir_all(copy.parent().unwrap()).unwrap();
            fs::write(&copy, HOOK.replace("NAME", name)).unwrap();
        }
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

/// The kind and name of each warning, the view a failure message prints.
fn warned(report: &EngineReport) -> Vec<(ItemKind, String)> {
    report
        .warnings
        .iter()
        .map(|w| (w.kind, w.name.clone()))
        .collect()
}

/// The paths a plan op other than a trash writes whose file name opens with
/// `name`, the view a failure message prints.
fn written_files(report: &EngineReport, name: &str) -> Vec<PathBuf> {
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

/// The hook the retired hook's header requires in the companion row.
const COMPANION: &str = "companion-check";

/// One row per item kind and catalog state: the retired hook removed;
/// still carried, as the KEN-2967 stub is; carried with a header requiring
/// a companion the catalog also carries, as the pre-retirement header of
/// doc-drift-check required lane-mail-check; and a retired skill whose
/// catalog names a migration. Each hook row's Copilot registry, left
/// holding only its version, goes with the hook.
#[test]
#[allow(clippy::unwrap_used)]
fn a_retired_item_still_declared_is_skipped_with_one_warning_and_swept() {
    for (row, kind, name, carried, requires_companion, migration) in [
        (
            "catalog removed it",
            ItemKind::Hook,
            "doc-drift-check",
            false,
            false,
            "",
        ),
        (
            "catalog carries it",
            ItemKind::Hook,
            "doc-drift-check",
            true,
            false,
            "",
        ),
        (
            "catalog carries it requiring a companion",
            ItemKind::Hook,
            "doc-drift-check",
            true,
            true,
            "",
        ),
        (
            "a skill with a migration",
            ItemKind::Skill,
            "deploy",
            true,
            false,
            "declare deploy-next",
        ),
    ] {
        let f = installed(kind, name);
        let catalog_copy = f.catalog_copy(kind, name);
        if !carried {
            fs::remove_file(&catalog_copy).unwrap();
        }
        if requires_companion {
            let stub = fs::read_to_string(&catalog_copy).unwrap();
            let requiring = stub.replacen(
                "# ---\nexit",
                &format!("# requires: [{COMPANION}]\n# ---\nexit"),
                1,
            );
            assert_ne!(requiring, stub, "{row}: the stub header took no requires");
            fs::write(&catalog_copy, requiring).unwrap();
            write_item(&f, ItemKind::Hook, COMPANION);
        }
        f.retire(kind, name, migration);

        let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();

        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Complete,
            "{row}"
        );
        assert_eq!(not_found_keys(&report), Vec::<String>::new(), "{row}");
        assert_eq!(warned(&report), [(kind, name.to_owned())], "{row}");
        let retired = &report.warnings[0];
        assert_eq!(retired.harness, None, "{row}");
        // The line the consumer refresh report (KEN-2797) forwards from a
        // `kendex refresh` capture: the name, a colon, one space; then the
        // catalog's migration, which the line carries whole.
        assert!(
            retired.message.starts_with(&format!("{name}: ")),
            "{row}: the warning message is not keyed by the item name"
        );
        assert!(
            retired.message.ends_with(migration),
            "{row}: the warning does not carry the migration"
        );
        for written in [name, COMPANION] {
            let files = written_files(&report, written);
            assert_eq!(files, Vec::<PathBuf>::new(), "{row}: {written}");
        }
        let trashed = trash_paths(&report);
        apply::execute(&f.env, &report.plan).unwrap();
        for copy in f.installed_copies(kind, name) {
            assert!(
                !copy.exists(),
                "{row}: {} stays; trashed: {trashed:?}",
                copy.display()
            );
        }
        assert!(
            !kendex_core::lock::load(&f.project.join(".kendex-lock.json"))
                .unwrap()
                .entries
                .values()
                .any(|entry| entry.name == name),
            "{row}: the record keeps the retired item"
        );
    }
}

/// The must-fail control: a hook name that is merely absent keeps the
/// refusal, and its installed copy stays where a refusal keeps it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unknown_hook_name_keeps_the_refusal() {
    let f = installed(ItemKind::Hook, "other-check");
    fs::remove_file(f.catalog_copy(ItemKind::Hook, "other-check")).unwrap();

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
    assert_eq!(warned(&report), Vec::<(ItemKind, String)>::new());
    let trashed = trash_paths(&report);
    for copy in f.installed_copies(ItemKind::Hook, "other-check") {
        assert!(!trashed.contains(&copy), "trashed: {trashed:?}");
    }
}

/// A hook whose header requires a hook the catalog then retires is withheld
/// with a warning of its own rather than left armed beside a judge that is
/// gone, and both installed copies come out.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_requiring_a_retired_hook_is_withheld_and_comes_out() {
    let f = installed(ItemKind::Hook, "boss");
    write_item(&f, ItemKind::Hook, "judge");
    let boss = f.catalog_copy(ItemKind::Hook, "boss");
    let header = fs::read_to_string(&boss).unwrap();
    fs::write(
        &boss,
        header.replacen("# ---\nexit", "# requires: [judge]\n# ---\nexit", 1),
    )
    .unwrap();
    let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    for copy in f.installed_copies(ItemKind::Hook, "judge") {
        assert!(copy.exists(), "the fixture installs {}", copy.display());
    }
    f.retire(ItemKind::Hook, "judge", "");

    let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();

    assert_eq!(not_found_keys(&report), Vec::<String>::new());
    assert_eq!(warned(&report), [(ItemKind::Hook, "boss".to_owned())]);
    assert_eq!(written_files(&report, "judge"), Vec::<PathBuf>::new());
    apply::execute(&f.env, &report.plan).unwrap();
    for name in ["boss", "judge"] {
        for copy in f.installed_copies(ItemKind::Hook, name) {
            assert!(!copy.exists(), "{} stays", copy.display());
        }
    }
}

/// A declaration deleted from kendex.toml by hand leaves a record nothing
/// declares or derives. Refresh takes its copies; one the person edited
/// stays, as the edit conflict. Without the sweep the leftover's row names
/// the removal that takes it.
#[test]
#[allow(clippy::unwrap_used)]
fn refresh_takes_what_a_deleted_declaration_left_except_an_edited_copy() {
    for edited in [false, true] {
        let f = installed(ItemKind::Hook, "other-check");
        let manifest = f.project.join("kendex.toml");
        let text = fs::read_to_string(&manifest).unwrap();
        let undeclared = text.replace("[hooks.other-check]\nsource = \"cat\"\n", "");
        assert_ne!(undeclared, text, "the declaration was not deleted");
        fs::write(&manifest, undeclared).unwrap();
        let script = f.project.join(".claude/hooks/other-check.sh");
        if edited {
            let mut bytes = fs::read_to_string(&script).unwrap();
            bytes.push_str("# the person's line\n");
            fs::write(&script, bytes).unwrap();
        }

        let audited = audit(&f.env, &f.scope).unwrap();
        let left = audited
            .drift
            .iter()
            .find(|row| row.name == "other-check" && row.state == DriftState::Orphaned)
            .unwrap();
        assert!(
            left.detail.contains("remove other-check"),
            "edited={edited}: the leftover row names no removal"
        );

        let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();
        let trashed = trash_paths(&report);
        assert_eq!(trashed.contains(&script), !edited, "edited={edited}");
        assert_eq!(
            report.drift.iter().any(|row| row.name == "other-check"
                && row.state == DriftState::Conflict
                && row.cause == Some(DriftCause::LocalEdit)),
            edited,
            "edited={edited}"
        );
        apply::execute(&f.env, &report.plan).unwrap();
        assert_eq!(script.exists(), edited, "edited={edited}");
    }
}
