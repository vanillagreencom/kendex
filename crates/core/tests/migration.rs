//! The v0.1 → v0.2 schema migration: journaled, transactional, surgical.
#![cfg(unix)]

use std::fs;

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest::MANIFEST_SCHEMA;
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    manifest_path: std::path::PathBuf,
    original: String,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("skills/gh")).unwrap();
    fs::write(
        source.join("skills/gh/SKILL.md"),
        "---\nname: gh\n---\nBody.\n",
    )
    .unwrap();

    // Hand-formatted v0.1 manifest: the upgrade must change the schema line
    // and nothing else.
    let original = format!(
        "# my project setup\nschema = 1\n\n[sources.cat]\npath = \"{}\"   # local catalog\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
        source.display()
    );
    let manifest_path = project.join("kendex.toml");
    fs::write(&manifest_path, &original).unwrap();
    fs::write(
        project.join(".kendex-lock.json"),
        "{\n  \"version\": 1,\n  \"entries\": {}\n}\n",
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        manifest_path,
        original,
        _tmp: tmp,
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_v01_scope_upgrades_in_place_changing_only_the_schema_line() {
    let f = fixture();
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .plan
            .ops
            .iter()
            .any(|op| op.description.contains("Upgrade kendex.toml"))
    );
    apply::execute(&f.env, &report.plan, None).unwrap();

    let migrated = fs::read_to_string(&f.manifest_path).unwrap();
    assert_eq!(
        migrated,
        f.original
            .replacen("schema = 1", &format!("schema = {MANIFEST_SCHEMA}"), 1)
    );
    let lock = load_lock(&lock_path(&f.env, &f.scope)).unwrap();
    assert_eq!(lock.version, kendex_core::lock::LOCK_VERSION);
    assert!(lock.entries.contains_key("skill:gh:claude"));

    // Idempotent: the migrated scope plans no further upgrade.
    let again = audit(&f.env, &f.scope).unwrap();
    assert!(
        !again
            .plan
            .ops
            .iter()
            .any(|op| op.description.contains("Upgrade"))
    );
    assert!(again.drift.is_empty());
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_interrupted_migration_rolls_back_byte_identically() {
    let f = fixture();
    let report = audit(&f.env, &f.scope).unwrap();
    let boundaries = report.plan.ops.len();
    for boundary in 0..boundaries {
        let error = apply::execute(&f.env, &report.plan, Some(boundary)).unwrap_err();
        assert!(matches!(error, CoreError::RolledBack { .. }));
        assert_eq!(fs::read_to_string(&f.manifest_path).unwrap(), f.original);
    }
}

/// A comment that merely mentions the schema line must never absorb the
/// rewrite; the real assignment below it is the one that changes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_comment_mentioning_the_schema_line_is_not_the_schema_line() {
    let f = fixture();
    let tricky = f.original.replacen(
        "# my project setup",
        "# was schema = 1 before the migration",
        1,
    );
    fs::write(&f.manifest_path, &tricky).unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();

    let migrated = fs::read_to_string(&f.manifest_path).unwrap();
    assert_eq!(
        migrated,
        tricky.replace("schema = 1\n", &format!("schema = {MANIFEST_SCHEMA}\n"))
    );
    assert!(migrated.contains("# was schema = 1 before the migration"));
}

/// Non-canonical but valid spellings upgrade in place too — compact
/// spacing and a trailing comment survive byte-for-byte; nothing falls
/// back to a whole-file rewrite that would strip comments.
#[test]
#[allow(clippy::unwrap_used)]
fn unusual_schema_spellings_upgrade_in_place() {
    for (spelling, upgraded) in [
        ("schema=1".to_owned(), format!("schema={MANIFEST_SCHEMA}")),
        (
            "schema = 1   # v0.1".to_owned(),
            format!("schema = {MANIFEST_SCHEMA}   # v0.1"),
        ),
    ] {
        let f = fixture();
        let variant = f.original.replacen("schema = 1", &spelling, 1);
        fs::write(&f.manifest_path, &variant).unwrap();

        let report = audit(&f.env, &f.scope).unwrap();
        apply::execute(&f.env, &report.plan, None).unwrap();

        let migrated = fs::read_to_string(&f.manifest_path).unwrap();
        assert_eq!(migrated, variant.replacen(&spelling, &upgraded, 1));
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_newer_schema_refuses_to_load() {
    let f = fixture();
    fs::write(
        &f.manifest_path,
        f.original.replacen("schema = 1", "schema = 99", 1),
    )
    .unwrap();
    assert!(matches!(
        audit(&f.env, &f.scope),
        Err(CoreError::SchemaTooNew { .. })
    ));
}

/// A caller can hand in a manifest carrying edits the file does not have —
/// a save in flight does exactly that. Upgrading the schema by rewriting
/// one line of the file would drop those edits, and the file write it
/// emits is not one `persists_manifest` recognises, so the caller adds its
/// own whole-file save and the two bind to the same bytes: the second
/// fails after the first has moved them, taking the save down with it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_upgrade_carrying_a_callers_edits_is_one_write_the_caller_can_see() {
    let f = fixture();
    let lock = load_lock(&lock_path(&f.env, &f.scope)).unwrap();
    let mut edited = kendex_core::manifest::load_for_mutation(&f.manifest_path)
        .unwrap()
        .unwrap();
    // The state a save in flight hands in: the schema the file still
    // carries, plus an edit the file does not.
    // The schema the file itself carries, so the surgical rewrite is the
    // path that would otherwise be taken.
    edited.schema = 1;
    edited
        .install
        .harnesses
        .push(kendex_core::model::HarnessId::Codex);

    let report = kendex_core::engine::plan_scope(
        &f.env,
        &f.scope,
        &edited,
        &lock,
        &kendex_core::engine::PlanOptions::default(),
    )
    .unwrap();

    assert!(
        kendex_core::engine::persists_manifest(&report.plan.ops),
        "the caller cannot see this write, so it will add a second one"
    );
    apply::execute(&f.env, &report.plan, None).unwrap();

    let written = kendex_core::manifest::load_for_mutation(&f.manifest_path)
        .unwrap()
        .unwrap();
    assert_eq!(
        written.schema, MANIFEST_SCHEMA,
        "the upgrade still happened"
    );
    assert!(
        written
            .install
            .harnesses
            .contains(&kendex_core::model::HarnessId::Codex),
        "and the caller's edit rode along rather than being dropped"
    );
}
