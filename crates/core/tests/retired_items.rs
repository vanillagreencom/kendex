//! An item its catalog retires (`[retired]` in the catalog's kendex.toml)
//! is never rendered again, whether or not the catalog still carries it,
//! and derives no companion its header requires. A plain refresh keeps
//! what is installed exactly as recorded, with one notice keyed by the
//! item's name that carries the catalog's migration, and a kept copy
//! deleted or edited by hand is a conflict. A prune takes the
//! copies, an emptied Copilot registry and a Pi package's registration with
//! them, the records and the item's own declaration. Where nothing of it is
//! kept, pruned or never installed, it is owed nothing. An armed hook
//! requiring it is withheld, kept or not. A rebound declaration keeps the
//! source conflict. Every other name the catalog does not carry keeps the
//! refusal that fails a refresh, so a retirement cannot hide a typo.
//! Refresh also takes what a declaration deleted by hand left, except a
//! copy the person edited.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::PathBuf;

use kendex_core::apply::{self, Op};
use kendex_core::engine::ops;
use kendex_core::engine::{
    AgentModelRequest, DeclarationStatus, DriftCause, DriftState, EngineReport, PlanOptions,
    RowRemedy, agent_model_request, audit, plan_apply, planned_closure,
};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::{lock, pi_ext};

const HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: NAME\n# event: PreToolUse\n# matcher: Bash\n# description: hold the call\n# ---\nexit 0\n";

const SKILL: &str = "---\nname: NAME\ndescription: Ship it\n---\n\nSteps.\n";

const PACKAGE: &str = r#"{"name":"NAME","version":"1.0.0","pi":{"extensions":["index.js"]}}"#;

const CATALOG: &str = "is_source_catalog = true\n";

/// How the consumer comes to want the item: its own declaration, or a
/// bundle of the catalog's it declares.
#[derive(Clone, Copy, Debug)]
enum Wanted {
    Declared,
    InBundle,
}

/// The bundle a [`Wanted::InBundle`] item comes in.
const BUNDLE: &str = "kit";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
    /// The catalog's kendex.toml before any retirement.
    catalog: String,
}

impl Fixture {
    /// Where the catalog keeps `name` of `kind`.
    fn catalog_copy(&self, kind: ItemKind, name: &str) -> PathBuf {
        match kind {
            ItemKind::Skill => self.source.join("skills").join(name),
            ItemKind::PiExtension => self.source.join("pi-extensions").join(name),
            _ => self.source.join("hooks").join(format!("{name}.sh")),
        }
    }

    /// The files an install of `name` of `kind` writes on each tool.
    #[allow(clippy::unwrap_used)]
    fn installed_copies(&self, kind: ItemKind, name: &str) -> Vec<PathBuf> {
        match kind {
            ItemKind::Skill => vec![self.project.join(".claude/skills").join(name)],
            ItemKind::PiExtension => {
                let root = pi_ext::scope_root(&self.env, &self.scope).unwrap();
                vec![pi_ext::package_path(&root, name).unwrap()]
            }
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
                "{}\n[retired.{}s]\n{name} = \"{migration}\"\n",
                self.catalog,
                kind.name()
            ),
        )
        .unwrap();
    }
}

/// A Claude Code and Copilot project that declares `name` of `kind` from a
/// catalog carrying it, with the item installed.
fn installed(kind: ItemKind, name: &str) -> Fixture {
    installed_as(kind, name, Wanted::Declared)
}

/// [`installed`], the item wanted as `wanted` says. A Pi package installs
/// through its carrier and is recorded as `update-pi` records it.
#[allow(clippy::unwrap_used)]
fn installed_as(kind: ItemKind, name: &str, wanted: Wanted) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(project.join(".github")).unwrap();
    let source = home.join("catalog");
    let (catalog, declaration) = match wanted {
        Wanted::Declared => (CATALOG.to_owned(), format!("[{}s.{name}]", kind.name())),
        Wanted::InBundle => (
            format!(
                "{CATALOG}\n[bundles.{BUNDLE}]\ndescription = \"the kit\"\n{}s = [\"{name}\"]\n",
                kind.name()
            ),
            format!("[bundles.{BUNDLE}]"),
        ),
    };
    let f = Fixture {
        _tmp: tmp,
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        source,
        catalog,
    };
    write_item(&f, kind, name);
    fs::write(f.source.join("kendex.toml"), &f.catalog).unwrap();
    fs::write(
        f.project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\", \"copilot\"]\nmethod = \"copy\"\n\n{declaration}\nsource = \"cat\"\n",
            source_path(&f.source),
        ),
    )
    .unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    if kind == ItemKind::PiExtension {
        let root = pi_ext::scope_root(&f.env, &f.scope).unwrap();
        pi_ext::install(&f.env, &root, &f.catalog_copy(kind, name), true).unwrap();
        let path = lock::lock_path(&f.env, &f.scope);
        let mut record = lock::load(&path).unwrap();
        let declared = kendex_core::engine::ops::manifest_for_reading(&f.env, &f.scope).unwrap();
        pi_ext::record_matching_manifest(
            &f.env,
            &f.scope,
            &declared,
            &mut record,
            pi_ext::RecordBasis::MatchedBytes,
            None,
        )
        .unwrap();
        lock::save(&path, &record).unwrap();
    }
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
        ItemKind::PiExtension => {
            fs::create_dir_all(&copy).unwrap();
            fs::write(copy.join("package.json"), PACKAGE.replace("NAME", name)).unwrap();
            fs::write(
                copy.join("index.js"),
                "export default function ext(pi) {}\n",
            )
            .unwrap();
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

/// `refresh --prune`'s plan.
fn prune_options() -> PlanOptions {
    PlanOptions {
        prune_retired: true,
        ..refresh_options()
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

/// The paths a plan op other than a removal writes whose file name opens
/// with `name`, the view a failure message prints.
fn written_files(report: &EngineReport, name: &str) -> Vec<PathBuf> {
    report
        .plan
        .ops
        .iter()
        .filter(|op| !matches!(op.op, Op::Trash { .. } | Op::PiRemove { .. }))
        .flat_map(|op| op.op.touched())
        .filter(|path| {
            path.file_name()
                .is_some_and(|file| file.to_string_lossy().starts_with(name))
        })
        .collect()
}

/// The paths the plan takes away, a trashed file or a removed Pi package,
/// the view a failure message prints.
fn trash_paths(report: &EngineReport) -> Vec<PathBuf> {
    report
        .plan
        .ops
        .iter()
        .filter_map(|op| match &op.op {
            Op::Trash { path, .. } => Some(path.clone()),
            Op::PiRemove { package, .. } => Some(package.clone()),
            _ => None,
        })
        .collect()
}

/// The hook the retired hook's header requires in the companion row.
const COMPANION: &str = "companion-check";

/// One row per item kind, catalog state and way of wanting it, kept by a
/// plain refresh and then pruned: the
/// retired hook removed; still carried, as the KEN-2967 stub is; carried
/// with a header requiring a companion the catalog also carries, as the
/// pre-retirement header of doc-drift-check required lane-mail-check; a
/// retired skill whose catalog names a migration, declared and as a bundle
/// member carried and removed; and a Pi package carried and removed, which
/// refuses a switch while kept. Each hook row's Copilot registry, left
/// holding only its version, goes with the hook.
#[test]
#[allow(clippy::unwrap_used, clippy::too_many_lines)]
fn a_retired_item_is_kept_with_one_notice_until_a_prune() {
    use Wanted::{Declared, InBundle};
    for (row, kind, name, wanted, carried, requires_companion, migration) in [
        (
            "catalog removed it",
            ItemKind::Hook,
            "doc-drift-check",
            Declared,
            false,
            false,
            "",
        ),
        (
            "catalog carries it",
            ItemKind::Hook,
            "doc-drift-check",
            Declared,
            true,
            false,
            "",
        ),
        (
            "catalog carries it requiring a companion",
            ItemKind::Hook,
            "doc-drift-check",
            Declared,
            true,
            true,
            "",
        ),
        (
            "a skill with a migration",
            ItemKind::Skill,
            "deploy",
            Declared,
            true,
            false,
            "declare deploy-next",
        ),
        (
            "a skill a declared bundle lists",
            ItemKind::Skill,
            "deploy",
            InBundle,
            true,
            false,
            "declare deploy-next",
        ),
        (
            "a skill a declared bundle lists, the catalog removed it",
            ItemKind::Skill,
            "deploy",
            InBundle,
            false,
            false,
            "",
        ),
        (
            "a Pi package the catalog carries",
            ItemKind::PiExtension,
            "old-ext",
            Declared,
            true,
            false,
            "declare new-ext",
        ),
        (
            "a Pi package the catalog removed",
            ItemKind::PiExtension,
            "old-ext",
            Declared,
            false,
            false,
            "",
        ),
    ] {
        let f = installed_as(kind, name, wanted);
        let catalog_copy = f.catalog_copy(kind, name);
        if !carried {
            match catalog_copy.is_dir() {
                true => fs::remove_dir_all(&catalog_copy).unwrap(),
                false => fs::remove_file(&catalog_copy).unwrap(),
            }
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

        let recorded = recorded_of(&f, name);
        assert!(!recorded.is_empty(), "{row}: the fixture records nothing");

        let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();

        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Complete,
            "{row}"
        );
        assert_eq!(not_found_keys(&report), Vec::<String>::new(), "{row}");
        assert_eq!(warned(&report), [(kind, name.to_owned())], "{row}");
        let notice = &report.warnings[0];
        assert_eq!(notice.harness, None, "{row}");
        // The key the CLI prints the notice bare under
        // (`engine_common::keyed_by_target`), the name, a colon and one
        // space. The catalog's migration ends the line, whole.
        assert!(
            notice.message.starts_with(&format!("{name}: ")),
            "{row}: the notice is not keyed by the item name"
        );
        match migration.is_empty() {
            false => assert!(
                notice.message.ends_with(&format!("; {migration}")),
                "{row}: the notice does not carry the migration"
            ),
            true => assert!(
                !notice.message.ends_with(';') && !notice.message.ends_with(' '),
                "{row}: an empty migration leaves a trailing separator"
            ),
        }
        for written in [name, COMPANION] {
            let files = written_files(&report, written);
            assert_eq!(files, Vec::<PathBuf>::new(), "{row}: {written}");
        }
        // Apply, which removes orphans, keeps it too.
        let applied = PlanOptions {
            remove_orphans: true,
            ..PlanOptions::default()
        };
        let applying = plan_apply(&f.env, &f.scope, &applied).unwrap();
        for planned in [&report, &applying] {
            let trashed = trash_paths(planned);
            for copy in f.installed_copies(kind, name) {
                assert!(!trashed.contains(&copy), "{row}: kept, yet {trashed:?}");
            }
        }
        apply::execute(&f.env, &report.plan).unwrap();
        for copy in f.installed_copies(kind, name) {
            assert!(copy.exists(), "{row}: kept, yet {} is gone", copy.display());
        }
        assert_eq!(recorded_of(&f, name), recorded, "{row}: the record moved");
        if kind == ItemKind::PiExtension {
            let switched = ops::toggle(
                &f.env,
                &f.scope,
                &[name.to_owned()],
                Some(kind),
                false,
                None,
            );
            assert!(
                matches!(&switched, Err(CoreError::PiPackage { name: refused, .. }) if refused == name),
                "{row}: a kept retired package was switched"
            );
        }

        let pruned = plan_apply(&f.env, &f.scope, &prune_options()).unwrap();

        assert_eq!(not_found_keys(&pruned), Vec::<String>::new(), "{row}");
        assert_eq!(warned(&pruned), Vec::<(ItemKind, String)>::new(), "{row}");
        for written in [name, COMPANION] {
            let files = written_files(&pruned, written);
            assert_eq!(files, Vec::<PathBuf>::new(), "{row}: {written}");
        }
        let trashed = trash_paths(&pruned);
        apply::execute(&f.env, &pruned.plan).unwrap();
        for copy in f.installed_copies(kind, name) {
            assert!(
                !copy.exists(),
                "{row}: {} stays; trashed: {trashed:?}",
                copy.display()
            );
        }
        assert_eq!(
            recorded_of(&f, name),
            Vec::new(),
            "{row}: the record keeps it"
        );
        let manifest = kendex_core::engine::ops::manifest_for_reading(&f.env, &f.scope).unwrap();
        assert!(
            !manifest.declared(kind).contains_key(name),
            "{row}: the declaration stays"
        );
        assert_eq!(
            manifest.bundles.contains_key(BUNDLE),
            matches!(wanted, InBundle),
            "{row}: the bundle declaration moved"
        );

        // A plain refresh after the prune owes the item nothing, a bundle
        // still listing it included, and says nothing of it.
        let after = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();

        assert_eq!(warned(&after), Vec::<(ItemKind, String)>::new(), "{row}");
        for written in [name, COMPANION] {
            let files = written_files(&after, written);
            assert_eq!(files, Vec::<PathBuf>::new(), "{row}: {written}");
        }
    }
}

/// The lock entries naming `name`, as the record on disk holds them.
#[allow(clippy::unwrap_used)]
fn recorded_of(f: &Fixture, name: &str) -> Vec<lock::LockEntry> {
    lock::load(&lock::lock_path(&f.env, &f.scope))
        .unwrap()
        .entries
        .into_values()
        .filter(|entry| entry.name == name)
        .collect()
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

/// What became of the judge before its catalog retired it.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Before {
    Installed,
    SwitchedOff,
    NeverInstalled,
}

/// What the person did after the retirement, ahead of a plain refresh.
#[derive(Clone, Copy, Debug, PartialEq)]
enum After {
    Nothing,
    Pruned,
    RemovedByName,
}

/// Which hooks stand over the retired judge: boss alone; a declared top
/// requiring boss, so top takes on boss's withholding; or boss requiring a
/// live helper beside the judge, so the helper is left with no requirer.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Over {
    Boss,
    Chain,
    WithHelper,
}

impl Over {
    /// Every hook this shape installs over the judge.
    fn hooks(self) -> &'static [&'static str] {
        match self {
            Over::Boss => &["boss"],
            Over::Chain => &["top", "boss"],
            Over::WithHelper => &["boss", "helper"],
        }
    }
}

/// The catalog's copy of hook `name` with a header requiring `deps`.
#[allow(clippy::unwrap_used)]
fn require(f: &Fixture, name: &str, deps: &str) {
    let copy = f.catalog_copy(ItemKind::Hook, name);
    let header = fs::read_to_string(&copy).unwrap();
    let required = header.replacen(
        "# ---\nexit",
        &format!("# requires: [{deps}]\n# ---\nexit"),
        1,
    );
    assert_ne!(required, header, "{name}: no header to require from");
    fs::write(&copy, required).unwrap();
}

/// A hook whose header requires a hook the catalog retires is withheld
/// on the tools it requires it on, with a warning of its own carrying the
/// catalog's migration where there is one, rather than armed beside a
/// judge that is never written again, whether the judge is kept, pruned,
/// never installed, switched off or removed by name. A hook requiring that
/// hook is withheld with it, and a companion only it required goes too.
/// The declarations stay complete: the retirement is the catalog's
/// answer, so the walks outside a plan, the closure and the managed agent
/// lookup, read it as one too.
#[test]
#[allow(clippy::unwrap_used, clippy::too_many_lines)]
fn a_hook_requiring_a_retired_hook_is_withheld() {
    for (row, over, before, after, migration) in [
        (
            "installed, then retired: kept",
            Over::Boss,
            Before::Installed,
            After::Nothing,
            "",
        ),
        (
            "installed, then retired with a migration and pruned",
            Over::Boss,
            Before::Installed,
            After::Pruned,
            "declare judge-next",
        ),
        (
            "retired before its first install",
            Over::Boss,
            Before::NeverInstalled,
            After::Nothing,
            "",
        ),
        (
            "switched off, then retired",
            Over::Boss,
            Before::SwitchedOff,
            After::Nothing,
            "",
        ),
        (
            "installed, retired, then removed by name",
            Over::Boss,
            Before::Installed,
            After::RemovedByName,
            "",
        ),
        (
            "under a declared hook requiring boss, kept",
            Over::Chain,
            Before::Installed,
            After::Nothing,
            "",
        ),
        (
            "beside a live companion of boss's, kept",
            Over::WithHelper,
            Before::Installed,
            After::Nothing,
            "",
        ),
    ] {
        let f = installed(ItemKind::Hook, "boss");
        write_item(&f, ItemKind::Hook, "judge");
        match over {
            Over::Boss => require(&f, "boss", "judge"),
            Over::Chain => {
                require(&f, "boss", "judge");
                write_item(&f, ItemKind::Hook, "top");
                require(&f, "top", "boss");
                let manifest = f.project.join("kendex.toml");
                let mut text = fs::read_to_string(&manifest).unwrap();
                text.push_str("\n[hooks.top]\nsource = \"cat\"\n");
                fs::write(&manifest, text).unwrap();
            }
            Over::WithHelper => {
                write_item(&f, ItemKind::Hook, "helper");
                require(&f, "boss", "judge, helper");
            }
        }
        if before == Before::SwitchedOff {
            let manifest = f.project.join("kendex.toml");
            let mut text = fs::read_to_string(&manifest).unwrap();
            text.push_str("\n[hooks.judge]\nsource = \"cat\"\nenabled = false\n");
            fs::write(&manifest, text).unwrap();
        }
        if before != Before::NeverInstalled {
            let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();
            apply::execute(&f.env, &report.plan).unwrap();
            assert_ne!(
                recorded_of(&f, "judge"),
                Vec::new(),
                "{row}: no judge record"
            );
            if before == Before::Installed {
                for name in over.hooks() {
                    assert_ne!(recorded_of(&f, name), Vec::new(), "{row}: no {name} record");
                }
            }
        }
        f.retire(ItemKind::Hook, "judge", migration);
        let done = match after {
            After::Nothing => None,
            After::Pruned => Some(plan_apply(&f.env, &f.scope, &prune_options()).unwrap()),
            After::RemovedByName => {
                Some(ops::remove(&f.env, &f.scope, &["judge".to_owned()], None, false).unwrap())
            }
        };
        if let Some(done) = done {
            for name in over.hooks() {
                let files = written_files(&done, name);
                assert_eq!(files, Vec::<PathBuf>::new(), "{row}: {after:?} {name}");
            }
            apply::execute(&f.env, &done.plan).unwrap();
        }

        let plain = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();

        assert_eq!(
            plain.declaration_status,
            DeclarationStatus::Complete,
            "{row}"
        );
        assert_eq!(not_found_keys(&plain), Vec::<String>::new(), "{row}");
        assert!(
            warned(&plain).contains(&(ItemKind::Hook, "boss".to_owned())),
            "{row}: {:?}",
            warned(&plain)
        );
        if !migration.is_empty() {
            let remedies: Vec<Option<&str>> = plain
                .warnings
                .iter()
                .filter(|w| w.kind == ItemKind::Hook && w.name == "boss")
                .map(|w| w.remediation.as_deref())
                .collect();
            assert!(remedies.contains(&Some(migration)), "{row}: {remedies:?}");
        }
        for name in over.hooks().iter().chain(&["judge"]) {
            let files = written_files(&plain, name);
            assert_eq!(files, Vec::<PathBuf>::new(), "{row}: {name}");
        }
        apply::execute(&f.env, &plain.plan).unwrap();
        for name in over.hooks() {
            assert_eq!(
                recorded_of(&f, name),
                Vec::new(),
                "{row}: {name} is recorded"
            );
        }
        let kept = (before, after) == (Before::Installed, After::Nothing);
        for name in over.hooks().iter().chain(&["judge"]) {
            for copy in f.installed_copies(ItemKind::Hook, name) {
                let stays = kept && *name == "judge";
                assert_eq!(copy.exists(), stays, "{row}: {}", copy.display());
            }
        }
        let manifest = ops::manifest_for_reading(&f.env, &f.scope).unwrap();
        let (_, closure) = planned_closure(&f.env, &f.scope, &manifest);
        assert_eq!(closure, DeclarationStatus::Complete, "{row}");
        let lookup = agent_model_request(&f.env, &f.project, HarnessId::Claude, "scout");
        assert!(
            matches!(lookup, Ok(AgentModelRequest::Unmanaged)),
            "{row}: the managed agent lookup failed"
        );
    }
}

/// A declaration, of a hook or a Pi package, naming an item its catalog
/// retired before anything installed it: nothing is written, no
/// installation is owed, and the declaration gets its notice.
#[test]
#[allow(clippy::unwrap_used)]
fn a_retired_item_never_installed_is_owed_nothing() {
    for kind in [ItemKind::Hook, ItemKind::PiExtension] {
        let f = installed(ItemKind::Hook, "base");
        write_item(&f, kind, "fresh");
        let manifest = f.project.join("kendex.toml");
        let mut text = fs::read_to_string(&manifest).unwrap();
        text.push_str(&format!("\n[{}s.fresh]\nsource = \"cat\"\n", kind.name()));
        fs::write(&manifest, text).unwrap();
        f.retire(kind, "fresh", "");

        let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();

        assert_eq!(warned(&report), [(kind, "fresh".to_owned())], "{kind:?}");
        assert_eq!(
            written_files(&report, "fresh"),
            Vec::<PathBuf>::new(),
            "{kind:?}"
        );
        let owed: Vec<&String> = report
            .installations
            .iter()
            .filter(|(_, installation)| installation.name == "fresh")
            .map(|(key, _)| key)
            .collect();
        assert_eq!(owed, Vec::<&String>::new(), "{kind:?}");
    }
}

/// A hook or Pi package installed from one catalog, its declaration then
/// set to come from a second catalog that retires the name: the record is
/// the first catalog's, so a plain refresh keeps it and says so as the
/// source conflict a rebind always gets, rather than keeping it as the
/// second catalog's retired item.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declaration_rebound_to_a_catalog_that_retires_it_keeps_the_conflict() {
    for (kind, name) in [
        (ItemKind::Hook, "other-check"),
        (ItemKind::PiExtension, "other-ext"),
    ] {
        let f = installed(kind, name);
        let recorded = recorded_of(&f, name);
        let other = f.source.parent().unwrap().join("other");
        fs::create_dir_all(&other).unwrap();
        fs::write(
            other.join("kendex.toml"),
            format!("{CATALOG}[retired.{}s]\n{name} = \"\"\n", kind.name()),
        )
        .unwrap();
        let manifest = f.project.join("kendex.toml");
        let text = fs::read_to_string(&manifest).unwrap();
        let rebound = text
            .replacen(
                "\n\n[install]",
                &format!("\n\n[sources.other]\n{}\n\n[install]", source_path(&other)),
                1,
            )
            .replace(
                &format!("[{}s.{name}]\nsource = \"cat\"", kind.name()),
                &format!("[{}s.{name}]\nsource = \"other\"", kind.name()),
            );
        assert_eq!(
            rebound.matches("\"other\"").count(),
            1,
            "{kind:?}: not rebound"
        );
        fs::write(&manifest, rebound).unwrap();

        let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();

        let conflicts: Vec<_> = report
            .drift
            .iter()
            .filter(|row| row.name == name && row.state == DriftState::Conflict)
            .map(|row| row.harness)
            .collect();
        let held: Vec<_> = recorded.iter().map(|entry| entry.harness).collect();
        assert_eq!(conflicts, held, "{kind:?}");
        let kept: Vec<_> = report
            .record
            .entries
            .values()
            .filter(|entry| entry.name == name)
            .cloned()
            .collect();
        assert_eq!(
            kept, recorded,
            "{kind:?}: the record was rebound or dropped"
        );
    }
}

/// A declaration deleted from kendex.toml by hand leaves a record nothing
/// declares or derives. Refresh takes its copies, a hook's script or a Pi
/// package; one the person edited stays, as the edit conflict. Without the
/// sweep the leftover's row carries the removal that takes it.
#[test]
#[allow(clippy::unwrap_used)]
fn refresh_takes_what_a_deleted_declaration_left_except_an_edited_copy() {
    for (kind, name, edited) in [
        (ItemKind::Hook, "other-check", false),
        (ItemKind::Hook, "other-check", true),
        (ItemKind::PiExtension, "other-ext", false),
        (ItemKind::PiExtension, "other-ext", true),
    ] {
        let case = format!("{kind:?} edited={edited}");
        let f = installed(kind, name);
        let manifest = f.project.join("kendex.toml");
        let text = fs::read_to_string(&manifest).unwrap();
        let undeclared = text.replace(
            &format!("[{}s.{name}]\nsource = \"cat\"\n", kind.name()),
            "",
        );
        assert_ne!(undeclared, text, "{case}: the declaration was not deleted");
        fs::write(&manifest, undeclared).unwrap();
        let copy = f.installed_copies(kind, name).remove(0);
        let edited_file = match kind {
            ItemKind::PiExtension => copy.join("index.js"),
            _ => copy.clone(),
        };
        if edited {
            let mut bytes = fs::read_to_string(&edited_file).unwrap();
            bytes.push_str("// the person's line\n");
            fs::write(&edited_file, bytes).unwrap();
        }

        let audited = audit(&f.env, &f.scope).unwrap();
        let left = audited
            .drift
            .iter()
            .find(|row| row.name == name && row.state == DriftState::Orphaned)
            .unwrap();
        assert_eq!(left.remedy, Some(RowRemedy::Remove), "{case}");

        let report = plan_apply(&f.env, &f.scope, &refresh_options()).unwrap();
        let trashed = trash_paths(&report);
        assert_eq!(trashed.contains(&copy), !edited, "{case}: {trashed:?}");
        assert_eq!(
            report.drift.iter().any(|row| row.name == name
                && row.state == DriftState::Conflict
                && row.cause == Some(DriftCause::LocalEdit)),
            edited,
            "{case}"
        );
        assert_eq!(
            report
                .record
                .entries
                .values()
                .any(|entry| entry.name == name),
            edited,
            "{case}"
        );
        apply::execute(&f.env, &report.plan).unwrap();
        assert_eq!(copy.exists(), edited, "{case}");
    }
}

/// What the person did to a kept retired item's copy on one tool.
#[derive(Clone, Copy, Debug, PartialEq)]
enum ByHand {
    Untouched,
    Deleted,
    Edited,
}

/// A kept retired item is held to its record as any recorded item is: a
/// copy deleted or edited by hand on one tool is a conflict on that tool's
/// installation alone, its cause the retirement a refresh never fails on,
/// the plan `kendex verify` reads failing that row,
/// and an untouched copy raises none. A prune then takes the record of a
/// copy that is gone and holds an edited one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_kept_retired_copy_gone_or_edited_is_a_conflict() {
    for (kind, name, harness) in [
        (ItemKind::Hook, "doc-drift-check", HarnessId::Claude),
        (ItemKind::Skill, "deploy", HarnessId::Claude),
        (ItemKind::PiExtension, "old-ext", HarnessId::Pi),
    ] {
        for by_hand in [ByHand::Untouched, ByHand::Deleted, ByHand::Edited] {
            let case = format!("{kind:?} {by_hand:?}");
            let f = installed(kind, name);
            f.retire(kind, name, "");
            let copy = f.installed_copies(kind, name).remove(0);
            match by_hand {
                ByHand::Untouched => {}
                ByHand::Deleted if copy.is_dir() => fs::remove_dir_all(&copy).unwrap(),
                ByHand::Deleted => fs::remove_file(&copy).unwrap(),
                ByHand::Edited => {
                    let file = match kind {
                        ItemKind::Skill => copy.join("SKILL.md"),
                        ItemKind::PiExtension => copy.join("index.js"),
                        _ => copy.clone(),
                    };
                    let mut bytes = fs::read_to_string(&file).unwrap();
                    bytes.push_str("// the person's line\n");
                    fs::write(&file, bytes).unwrap();
                }
            }

            let report = audit(&f.env, &f.scope).unwrap();

            let conflicted: Vec<(HarnessId, Option<DriftCause>)> = report
                .drift
                .iter()
                .filter(|row| {
                    row.kind == kind && row.name == name && row.state == DriftState::Conflict
                })
                .map(|row| (row.harness, row.cause))
                .collect();
            let changed = match by_hand {
                ByHand::Untouched => vec![],
                ByHand::Deleted | ByHand::Edited => vec![(harness, Some(DriftCause::Retired))],
            };
            assert_eq!(conflicted, changed, "{case}");

            let pruned = plan_apply(&f.env, &f.scope, &prune_options()).unwrap();
            let key = lock::entry_key(kind, name, harness);
            assert_eq!(
                pruned.record.entries.contains_key(&key),
                by_hand == ByHand::Edited,
                "{case}"
            );
        }
    }
}
