//! What this build does with a manifest it cannot read: nothing at all.
//!
//! No importer exists, in either direction. A file below this build's
//! schema and one above it both refuse, the file is left exactly as it was
//! written, and the refusal names the way out.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{audit, ops};
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

/// A project declaring one skill, at whichever schema the caller names.
#[allow(clippy::unwrap_used)]
fn fixture(schema: &str) -> Fixture {
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

    // Hand-formatted, with a comment and odd spacing: the bytes a refusal
    // must leave exactly where the person put them.
    let original = format!(
        "# my project setup\nschema = {schema}\n\n[sources.cat]\n{}   # local catalog\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
        source_path(&source)
    );
    let manifest_path = project.join("kendex.toml");
    fs::write(&manifest_path, &original).unwrap();

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

/// A v0.1 manifest is not read, not converted, and not written over. The
/// refusal names it as an older schema and says what to do with it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_v01_manifest_is_refused_and_left_byte_identical() {
    let f = fixture("1");
    let error = audit(&f.env, &f.scope).unwrap_err();
    assert!(matches!(error, CoreError::LegacyManifest { .. }), "{error}");
    let said = error.to_string();
    assert!(said.contains("schema 1"), "{said}");
    assert!(said.contains("install fresh"), "{said}");
    assert_eq!(
        fs::read_to_string(&f.manifest_path).unwrap(),
        f.original,
        "a refusal writes nothing"
    );
    assert!(!f.scope_lock().exists(), "and installs nothing");
}

/// The schema this build writes is the schema it reads, so the same file
/// one number back is refused for the same reason as a v0.1 one.
#[test]
#[allow(clippy::unwrap_used)]
fn the_schema_one_below_current_is_refused_too() {
    let f = fixture(&(MANIFEST_SCHEMA - 1).to_string());
    let error = audit(&f.env, &f.scope).unwrap_err();
    assert!(matches!(error, CoreError::LegacyManifest { .. }), "{error}");
    assert_eq!(fs::read_to_string(&f.manifest_path).unwrap(), f.original);
}

/// A manifest naming no schema at all: the same refusal, saying that
/// nothing here can tell what shape the file is.
#[test]
#[allow(clippy::unwrap_used)]
fn a_manifest_naming_no_schema_is_refused() {
    let f = fixture("1");
    let unversioned = f.original.replace("schema = 1\n", "");
    fs::write(&f.manifest_path, &unversioned).unwrap();
    let error = audit(&f.env, &f.scope).unwrap_err();
    assert!(matches!(error, CoreError::LegacyManifest { .. }), "{error}");
    assert!(error.to_string().contains("no schema"), "{error}");
    assert_eq!(fs::read_to_string(&f.manifest_path).unwrap(), unversioned);
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_newer_schema_refuses_to_load() {
    let f = fixture("99");
    assert!(matches!(
        audit(&f.env, &f.scope),
        Err(CoreError::SchemaTooNew { found: 99, .. })
    ));
    assert_eq!(fs::read_to_string(&f.manifest_path).unwrap(), f.original);
}

/// An apply interrupted at any op boundary rolls the whole scope back:
/// manifest byte-identical, nothing installed, no record left behind
/// (invariant 7).
///
/// Planned through `add` rather than `audit`, because `add` is what puts
/// the declaration in the file. A plan over an already-declared skill
/// writes no manifest op at all, and the byte-identity assertion would
/// then hold whatever the rollback did.
///
/// The op that stops the apply is a real refusal: a write bound to
/// nothing being at the manifest's path, which the manifest occupies. So
/// the rollback under test is the one the product runs.
#[test]
#[allow(clippy::unwrap_used)]
fn an_interrupted_apply_rolls_the_whole_scope_back() {
    let f = fixture(&MANIFEST_SCHEMA.to_string());
    // Undeclared, so adding it is a manifest write.
    let undeclared = f
        .original
        .split_once("\n[skills.gh]")
        .map(|(kept, _)| format!("{kept}\n"))
        .unwrap();
    fs::write(&f.manifest_path, &undeclared).unwrap();

    let report = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            source: Some("cat".into()),
            skills: vec!["gh".into()],
            ..Default::default()
        },
    )
    .unwrap();
    assert!(
        report
            .plan
            .ops
            .iter()
            .any(|op| matches!(op.op, apply::Op::WriteManifest { .. })),
        "the plan must carry the manifest write the rollback has to undo: {:?}",
        report.plan.ops
    );
    let boundaries = report.plan.ops.len();
    assert!(boundaries > 1, "the plan must have boundaries to stop at");
    for boundary in 0..=boundaries {
        let mut plan = report.plan.clone();
        plan.insert(
            boundary,
            apply::PlannedOp {
                description: "refuse".into(),
                op: apply::Op::WriteFile {
                    path: f.manifest_path.clone(),
                    bytes: b"never written".to_vec(),
                    pre: apply::Pre::Absent,
                },
            },
        )
        .unwrap();
        let error = apply::execute(&f.env, &plan).unwrap_err();
        assert!(matches!(error, CoreError::RolledBack { .. }), "{error}");
        assert_eq!(
            fs::read_to_string(&f.manifest_path).unwrap(),
            undeclared,
            "at boundary {boundary}"
        );
        assert!(!f.scope_lock().exists(), "at boundary {boundary}");
        assert!(!f.installed_skill().exists(), "at boundary {boundary}");
    }

    // And the uninterrupted apply does land, so the loop above was
    // stopping a plan that had something to do.
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(f.installed_skill().exists());
    assert!(
        fs::read_to_string(&f.manifest_path)
            .unwrap()
            .contains("[skills.gh]")
    );
    let lock = load_lock(&lock_path(&f.env, &f.scope)).unwrap();
    assert_eq!(lock.version, kendex_core::lock::LOCK_VERSION);
    assert!(lock.entries.contains_key("skill:gh:claude"));
}

impl Fixture {
    fn project(&self) -> &std::path::Path {
        match &self.scope {
            Scope::Project { root } => root,
            Scope::Global => unreachable!("every fixture here is a project"),
        }
    }

    fn scope_lock(&self) -> std::path::PathBuf {
        self.project().join(".kendex-lock.json")
    }

    fn installed_skill(&self) -> std::path::PathBuf {
        self.project().join(".claude/skills/gh")
    }
}
