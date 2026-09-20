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
use kendex_core::engine::{PlanOptions, audit, ops, plan_apply, plan_record_existing};
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

/// A manifest this build cannot read is refused and left byte for byte
/// where the person put it, one row per schema: a v0.1 manifest is not
/// read, not converted and not written over, the refusal naming the
/// schema it found; the schema this build writes is the schema it reads,
/// so the same file one number back is refused for the same reason; a
/// manifest naming no schema at all gets the same refusal, saying that
/// nothing here can tell what shape the file is; and a newer schema is
/// its own refusal, naming the format found.
#[test]
#[allow(clippy::unwrap_used)]
fn a_manifest_this_build_cannot_read_is_refused_and_left_byte_identical() {
    enum Refusal {
        Legacy(String),
        TooNew(i64),
    }
    let one_below = (MANIFEST_SCHEMA - 1).to_string();
    let rows: [(&str, Option<&str>, Refusal); 4] = [
        (
            "schema 1",
            Some("1"),
            Refusal::Legacy("schema 1".to_owned()),
        ),
        (
            "one below current",
            Some(&one_below),
            Refusal::Legacy(format!("schema {one_below} manifest")),
        ),
        ("no schema", None, Refusal::Legacy("no schema".to_owned())),
        ("schema 99", Some("99"), Refusal::TooNew(99)),
    ];
    for (what, schema, refusal) in rows {
        let f = fixture(schema.unwrap_or("1"));
        if schema.is_none() {
            fs::write(&f.manifest_path, f.original.replace("schema = 1\n", "")).unwrap();
        }
        let before = fs::read_to_string(&f.manifest_path).unwrap();

        let error = audit(&f.env, &f.scope).unwrap_err();

        match (&refusal, &error) {
            (Refusal::Legacy(clause), CoreError::LegacyManifest { message, .. }) => {
                assert!(message.contains(clause), "{what}: {message}");
            }
            (Refusal::TooNew(expected), CoreError::SchemaTooNew { found, .. }) => {
                assert_eq!(found, expected, "{what}");
            }
            _ => panic!("{what}: {error:?}"),
        }
        assert_eq!(
            fs::read_to_string(&f.manifest_path).unwrap(),
            before,
            "{what}: a refusal writes nothing"
        );
        assert!(
            !f.scope_lock().exists(),
            "{what}: a refusal installs nothing"
        );
    }
}

/// When an install was made is this machine's half of the record. An
/// apply that changes nothing keeps the time it finds there; with the
/// half gone — a clone, a cleared cache — the record is re-made with the
/// time of this apply, which on this machine is when the install was
/// made. One row per state of the half, pinning the time each produces.
#[test]
#[allow(clippy::unwrap_used)]
fn the_install_time_is_kept_with_the_machine_half_and_fresh_without_it() {
    let planted = "2020-01-01T00:00:00Z";
    for (label, half_present) in [("the half present", true), ("the half gone", false)] {
        let f = fixture(&MANIFEST_SCHEMA.to_string());
        let install = plan_apply(&f.env, &f.scope, &PlanOptions::default()).unwrap();
        apply::execute(&f.env, &install.plan).unwrap();
        let lock_path = f.scope_lock();
        let mut lock = load_lock(&lock_path).unwrap();
        lock.entries
            .get_mut("skill:gh:claude")
            .unwrap()
            .machine
            .as_mut()
            .unwrap()
            .installed_at = planted.to_owned();
        kendex_core::lock::save(&lock_path, &lock).unwrap();
        if !half_present {
            fs::remove_file(kendex_core::lock::machine_path(&lock_path)).unwrap();
        }

        let before = kendex_core::clock::timestamp();
        let again = plan_apply(&f.env, &f.scope, &PlanOptions::default()).unwrap();
        apply::execute(&f.env, &again.plan).unwrap();
        let after = kendex_core::clock::timestamp();

        let recorded = load_lock(&lock_path).unwrap().entries["skill:gh:claude"]
            .machine
            .clone()
            .unwrap_or_else(|| panic!("{label}: the apply records the half"))
            .installed_at;
        if half_present {
            assert_eq!(recorded, planted, "{label}");
        } else {
            assert!(
                (before.as_str()..=after.as_str()).contains(&recorded.as_str()),
                "{label}: {recorded} is the time of this apply, between {before} and {after}"
            );
        }
    }
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
        assert!(
            !kendex_core::lock::machine_path(&f.scope_lock()).exists(),
            "at boundary {boundary}: this machine's half of the record goes back with the record"
        );
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

/// One row per state the repository's ignore file can be in when the
/// record is rebuilt: as the install left it, and carrying the managed
/// block an earlier build wrote, which named the record itself. Every
/// project that build managed is in the second state, and the recovery is
/// the command those projects are told to run: the block's refresh is
/// housekeeping, never evidence that the installs drifted, and it is done
/// in the same run, since a record written under a block that still
/// ignores it is a record no clone receives. The renders are untouched in
/// both rows.
#[test]
#[allow(clippy::unwrap_used)]
fn matching_renders_are_recorded_without_being_rewritten() {
    let as_installed: fn(&str) -> String = |ignore| ignore.to_owned();
    let earlier_block: fn(&str) -> String = |ignore| {
        ignore.replace(
            "# kendex:local-state begin\n/tmp/\n/.cache/\n",
            "# kendex:local-state begin\n/tmp/\n/.kendex-lock.json\n/.cache/\n",
        )
    };
    for (label, ignore_file, changes) in [
        ("as the install left it", as_installed, 1),
        ("the earlier build's managed block", earlier_block, 2),
    ] {
        let f = fixture(&MANIFEST_SCHEMA.to_string());
        let initialized = kendex_core::process::Hardened::git(&["init", "-q"], Some(f.project()))
            .run()
            .unwrap();
        assert!(initialized.status.success());
        let install = plan_apply(&f.env, &f.scope, &PlanOptions::default()).unwrap();
        apply::execute(&f.env, &install.plan).unwrap();
        let rendered = f.project().join(".agents/skills/gh/SKILL.md");
        let before = fs::read(&rendered).unwrap();
        let lock_path = f.scope_lock();
        fs::remove_file(&lock_path).unwrap();
        fs::remove_file(f.project().join(".kendex-generated.json")).unwrap();
        let ignore = f.project().join(".gitignore");
        let planted = ignore_file(&fs::read_to_string(&ignore).unwrap());
        assert_ne!(
            planted.is_empty() || planted == fs::read_to_string(&ignore).unwrap(),
            label == "the earlier build's managed block",
            "{label}: the fixture plants the state it names"
        );
        fs::write(&ignore, &planted).unwrap();

        let recovery = plan_record_existing(&f.env, &f.scope)
            .unwrap_or_else(|error| panic!("{label}: {error}"));
        assert_eq!(
            recovery.plan.ops.len(),
            changes,
            "{label}: the record, and the ignore block where it is stale"
        );
        assert!(
            recovery
                .plan
                .ops
                .iter()
                .any(|planned| matches!(planned.op, apply::Op::WriteLock { .. })),
            "{label}"
        );
        apply::execute(&f.env, &recovery.plan).unwrap();

        assert_eq!(fs::read(&rendered).unwrap(), before, "{label}");
        let ignore_after = fs::read_to_string(&ignore).unwrap();
        assert!(
            !ignore_after.contains(".kendex-lock.json"),
            "{label}: the record is not left ignored: {ignore_after}"
        );
        let recovered = load_lock(&lock_path).unwrap();
        assert_eq!(recovered.version, kendex_core::lock::LOCK_VERSION);
        assert!(recovered.entries.contains_key("skill:gh:claude"), "{label}");
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn recording_existing_refuses_a_render_that_does_not_match() {
    let f = fixture(&MANIFEST_SCHEMA.to_string());
    let install = plan_apply(&f.env, &f.scope, &PlanOptions::default()).unwrap();
    apply::execute(&f.env, &install.plan).unwrap();
    let rendered = f.project().join(".agents/skills/gh/SKILL.md");
    fs::write(&rendered, "person's edit\n").unwrap();
    let lock_path = f.scope_lock();
    fs::remove_file(&lock_path).unwrap();

    let error = plan_record_existing(&f.env, &f.scope).unwrap_err();
    assert!(
        matches!(error, CoreError::RecordExistingRefused { .. }),
        "{error}"
    );
    assert_eq!(fs::read_to_string(&rendered).unwrap(), "person's edit\n");
    assert!(!lock_path.exists());
}

#[test]
fn recovery_requires_the_whole_declared_set() {
    for extra in [
        "\n[bundles.missing]\nsource = \"cat\"\n",
        "\n[plugins.\"fmt@main\"]\nenabled = true\nharness = \"claude\"\n",
    ] {
        let f = fixture(&MANIFEST_SCHEMA.to_string());
        let install = plan_apply(&f.env, &f.scope, &PlanOptions::default()).unwrap();
        apply::execute(&f.env, &install.plan).unwrap();
        fs::remove_file(f.scope_lock()).unwrap();
        fs::write(&f.manifest_path, format!("{}{extra}", f.original)).unwrap();
        let error = plan_record_existing(&f.env, &f.scope).unwrap_err();
        assert!(
            matches!(error, CoreError::RecordExistingRefused { .. }),
            "incomplete declaration accepted: {extra}: {error}"
        );
        assert!(!f.scope_lock().exists());
    }
}

#[test]
fn recovery_rechecks_render_bytes_before_recording() {
    let f = fixture(&MANIFEST_SCHEMA.to_string());
    let install = plan_apply(&f.env, &f.scope, &PlanOptions::default()).unwrap();
    apply::execute(&f.env, &install.plan).unwrap();
    fs::remove_file(f.scope_lock()).unwrap();
    let recovery = plan_record_existing(&f.env, &f.scope).unwrap();
    let rendered = f.project().join(".agents/skills/gh/SKILL.md");
    fs::write(&rendered, "edited during confirmation\n").unwrap();
    let error = apply::execute(&f.env, &recovery.plan).unwrap_err();
    assert!(matches!(error, CoreError::RolledBack { .. }), "{error}");
    assert!(!f.scope_lock().exists());
    assert_eq!(
        fs::read_to_string(rendered).unwrap(),
        "edited during confirmation\n"
    );
}

#[test]
fn recovery_accepts_informational_dependency_notes() {
    let f = fixture(&MANIFEST_SCHEMA.to_string());
    let skills = f._tmp.path().join("catalog/skills");
    fs::write(
        skills.join("gh/SKILL.md"),
        "---\nname: gh\ndescription: fixture\ndependencies:\n  required: [peer]\n---\nBody.\n",
    )
    .unwrap();
    fs::create_dir_all(skills.join("peer")).unwrap();
    fs::write(
        skills.join("peer/SKILL.md"),
        "---\nname: peer\ndescription: fixture\ndependencies:\n  required: [gh]\n---\nBody.\n",
    )
    .unwrap();
    let adapter = kendex_core::harness::adapter(kendex_core::model::HarnessId::Codex);
    fs::create_dir_all(adapter.default_global_root(&f.env)).unwrap();
    let install = plan_apply(&f.env, &f.scope, &PlanOptions::default()).unwrap();
    assert!(
        install
            .notes
            .iter()
            .any(|note| note.contains("also installs"))
    );
    apply::execute(&f.env, &install.plan).unwrap();
    fs::remove_file(f.scope_lock()).unwrap();
    let recovery = plan_record_existing(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &recovery.plan).unwrap();
    let lock = load_lock(&f.scope_lock()).unwrap();
    assert!(lock.entries.values().any(|entry| entry.name == "peer"));
}

#[test]
fn recovery_refuses_an_unresolved_required_dependency() {
    let f = fixture(&MANIFEST_SCHEMA.to_string());
    fs::write(
        f._tmp.path().join("catalog/skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: fixture\ndependencies:\n  required: [missing]\n---\nBody.\n",
    )
    .unwrap();
    let install = plan_apply(&f.env, &f.scope, &PlanOptions::default()).unwrap();
    apply::execute(&f.env, &install.plan).unwrap();
    assert!(f.project().join(".agents/skills/gh/SKILL.md").is_file());
    fs::remove_file(f.scope_lock()).unwrap();
    let error = plan_record_existing(&f.env, &f.scope).unwrap_err();
    assert!(
        matches!(error, CoreError::RecordExistingRefused { .. }),
        "{error}"
    );
    assert!(!f.scope_lock().exists());
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
