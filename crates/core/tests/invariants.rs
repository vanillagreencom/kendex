//! The eight ARCHITECTURE invariants, exercised end-to-end on a fixture
//! project. Kind-specific extensions (structured-config toggles, shared
//! targets) extend these in Phase 3+.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::engine::{DriftState, audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::manifest;
use kendex_core::model::Scope;
use kendex_core::{apply, hash};

/// Writes a manifest the way an editor outside kendex would: raw bytes,
/// no base, no plan — production writes go through the apply, which is
/// why `manifest::save` is not public.
#[allow(clippy::unwrap_used)]
fn save_manifest(path: &std::path::Path, manifest: &manifest::Manifest) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, toml::to_string_pretty(manifest).unwrap()).unwrap();
}

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    // Canonical up front: macOS reaches its temp dirs through a symlink,
    // and the engine hands back canonical paths.
    let home = tmp.path().canonicalize().unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("skills/gh")).unwrap();
    fs::write(
        source.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github\n---\n\n# GitHub\n\nAuthor text.\n",
    )
    .unwrap();
    fs::create_dir_all(source.join("agents")).unwrap();
    fs::write(
        source.join("agents/rust.md"),
        "---\nname: rust\ndescription: Rust engineer\nmodel: opus\nrole: engineer\n---\n\nBody.\n",
    )
    .unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[agents.rust]\nsource = \"cat\"\n\n[skills.gh]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        source,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn drift_states(f: &Fixture) -> Vec<(String, DriftState)> {
    audit(&f.env, &f.scope)
        .unwrap()
        .drift
        .iter()
        .map(|row| (row.name.clone(), row.state))
        .collect()
}

fn agent_file(f: &Fixture) -> PathBuf {
    f.project.join(".claude/agents/rust.md")
}

fn canonical_skill(f: &Fixture) -> PathBuf {
    f.project.join(".agents/skills/gh")
}

#[test]
fn declare_apply_drift_clean_round_trips() {
    let f = fixture();
    apply_now(&f);
    assert!(agent_file(&f).is_file());
    assert!(canonical_skill(&f).join("SKILL.md").is_file());
    let link = f.project.join(".claude/skills/gh");
    // Relative, so the pair is committable: the same two files in a
    // teammate's checkout still point at each other.
    assert_eq!(
        fs::read_link(&link).unwrap(),
        Path::new("../../.agents/skills/gh")
    );
    assert_eq!(link.canonicalize().unwrap(), canonical_skill(&f));
    assert_eq!(drift_states(&f), vec![]);
}
#[test]
fn invariant_1_generated_artifacts_regenerate_but_never_over_an_edit() {
    let f = fixture();
    apply_now(&f);
    fs::write(agent_file(&f), "hand edit").unwrap();
    fs::write(canonical_skill(&f).join("SKILL.md"), "tampered").unwrap();

    // A hand-edited artifact is a conflict, not a casualty: the plan holds
    // it and names the ways out. Nothing regenerates over the edit.
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .all(|row| row.state == DriftState::Conflict
                && row.cause == Some(kendex_core::engine::DriftCause::LocalEdit)),
        "{:?}",
        report.drift
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(fs::read_to_string(agent_file(&f)).unwrap(), "hand edit");

    // Discarding the edits is the explicit act that restores regeneration.
    let report = kendex_core::engine::plan_scope(
        &f.env,
        &f.scope,
        &manifest::load_for_mutation(&manifest::manifest_path(&f.env, &f.scope))
            .unwrap()
            .unwrap(),
        &kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap(),
        &kendex_core::engine::PlanOptions {
            overwrite_edited: true,
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    assert!(
        fs::read_to_string(agent_file(&f))
            .unwrap()
            .contains("Generated by kendex")
    );
    assert!(
        fs::read_to_string(canonical_skill(&f).join("SKILL.md"))
            .unwrap()
            .contains("Author text.")
    );

    // Manifest customizations re-merge on regeneration.
    let path = manifest::manifest_path(&f.env, &f.scope);
    let mut m = manifest::load_for_mutation(&path).unwrap().unwrap();
    m.skill_instructions
        .insert("gh".into(), "prefer gh cli".into());
    save_manifest(&path, &m);
    apply_now(&f);
    let text = fs::read_to_string(canonical_skill(&f).join("SKILL.md")).unwrap();
    assert!(text.contains("prefer gh cli") && text.contains("Author text."));
}

#[test]
fn invariant_2_never_readd_a_user_removal() {
    let f = fixture();
    // The default source seeds exactly once: a fresh manifest carries it,
    // an existing manifest without it stays without it.
    let seeded = ops::manifest_for_mutation(&f.env, &Scope::Global).unwrap();
    assert!(seeded.sources.contains_key("kendex"));
    let global_path = manifest::manifest_path(&f.env, &Scope::Global);
    let mut stripped = seeded.clone();
    stripped.sources.clear();
    save_manifest(&global_path, &stripped);
    let reloaded = ops::manifest_for_mutation(&f.env, &Scope::Global).unwrap();
    assert!(reloaded.sources.is_empty());

    // Skill removals survive upstream refreshes; upstream additions merge.
    apply_now(&f); // records the upstream skill set (gh via role default? none — prefix)
    let path = manifest::manifest_path(&f.env, &f.scope);
    let mut m = manifest::load_for_mutation(&path).unwrap().unwrap();
    m.agent_skills.insert("rust".into(), vec![]);
    save_manifest(&path, &m);
    apply_now(&f);

    // Upstream gains a prefix-matching skill after the removal.
    fs::create_dir_all(f.source.join("skills/rust-perf")).unwrap();
    fs::write(
        f.source.join("skills/rust-perf/SKILL.md"),
        "---\nname: rust-perf\ndescription: perf\n---\nx\n",
    )
    .unwrap();
    apply_now(&f);
    let m = manifest::load_for_mutation(&path).unwrap().unwrap();
    assert_eq!(m.agent_skills["rust"], vec!["rust-perf".to_owned()]);
    let rendered = fs::read_to_string(agent_file(&f)).unwrap();
    assert!(rendered.contains("rust-perf"));
    // gh was removed by the user and never comes back.
    assert!(!rendered.contains("skills: gh"));
}

#[test]
fn invariant_3_shared_key_edits_invalidate_dependents() {
    let f = fixture();
    apply_now(&f);
    assert_eq!(drift_states(&f), vec![]);
    let path = manifest::manifest_path(&f.env, &f.scope);
    let mut m = manifest::load_for_mutation(&path).unwrap().unwrap();
    m.skill_instructions.insert("all".into(), "shared".into());
    save_manifest(&path, &m);
    let drift = drift_states(&f);
    assert!(drift.contains(&("gh".to_owned(), DriftState::Stale)));
}

#[test]
fn invariant_4_provenance_is_durable() {
    let f = fixture();
    apply_now(&f);

    // Same-source re-add: a no-op, not an error.
    let report = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            source: Some(f.source.display().to_string()),
            skills: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    // Same name from a different source: hard error naming the original.
    let other = f.project.join("other-catalog");
    fs::create_dir_all(other.join("skills/gh")).unwrap();
    fs::write(
        other.join("skills/gh/SKILL.md"),
        "---\nname: gh\n---\nimpostor\n",
    )
    .unwrap();
    let error = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            source: Some(other.display().to_string()),
            skills: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap_err();
    match error {
        CoreError::SourceCollision { name, existing, .. } => {
            assert_eq!(name, "gh");
            assert_eq!(
                existing,
                kendex_core::paths::canonical(&f.source)
                    .unwrap()
                    .display()
                    .to_string()
            );
        }
        other => panic!("expected SourceCollision, got {other}"),
    }
}

#[test]
fn invariant_5_toggle_is_lossless_rename() {
    let f = fixture();
    apply_now(&f);
    let enabled_agent = fs::read_to_string(agent_file(&f)).unwrap();

    let report = ops::toggle(&f.env, &f.scope, &["rust".into(), "gh".into()], None, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!agent_file(&f).exists());
    assert!(f.project.join(".claude/agents/rust.md.disabled").is_file());
    assert!(canonical_skill(&f).join("SKILL.md.disabled").is_file());
    assert!(!canonical_skill(&f).join("SKILL.md").exists());
    // Disabled is a state, not drift.
    assert_eq!(drift_states(&f), vec![]);

    let report = ops::toggle(&f.env, &f.scope, &["rust".into(), "gh".into()], None, true).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(fs::read_to_string(agent_file(&f)).unwrap(), enabled_agent);
    assert!(canonical_skill(&f).join("SKILL.md").is_file());
}

#[test]
fn invariant_6_never_touch_the_unowned() {
    let f = fixture();
    apply_now(&f);

    // An unmanaged sibling survives apply and managed removal.
    let stray = f.project.join(".claude/skills/handmade");
    fs::create_dir_all(&stray).unwrap();
    fs::write(stray.join("SKILL.md"), "mine").unwrap();
    let report = ops::remove(&f.env, &f.scope, &["gh".into()], None, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(fs::read_to_string(stray.join("SKILL.md")).unwrap(), "mine");
    assert!(!f.project.join(".claude/skills/gh").is_symlink());

    // Removal went to the trash, not oblivion.
    let trash_entries: Vec<_> = fs::read_dir(f.env.trash_dir()).unwrap().flatten().collect();
    assert!(!trash_entries.is_empty());

    // A foreign symlink at a managed target is a conflict, never clobbered.
    let foreign_target = f.project.join("elsewhere");
    fs::create_dir_all(&foreign_target).unwrap();
    std::os::unix::fs::symlink(&foreign_target, f.project.join(".claude/skills/gh")).unwrap();
    let report = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            source: Some(f.source.display().to_string()),
            skills: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    let drift = audit(&f.env, &f.scope).unwrap();
    assert!(drift.drift.iter().any(|r| r.state == DriftState::Conflict));
    assert_eq!(
        fs::read_link(f.project.join(".claude/skills/gh")).unwrap(),
        foreign_target
    );
}

/// A refusal at every position in the plan, each one rolling the ops
/// before it back. The refusal is real — an op bound to nothing being at
/// a path that already holds the manifest — so what this exercises is the
/// rollback the product runs, at every boundary it can stop at.
#[test]
fn invariant_7_applies_are_transactional() {
    let f = fixture();
    let before = hash::hash_tree(&f.project).unwrap();
    let op_count = audit(&f.env, &f.scope).unwrap().plan.ops.len();
    assert!(op_count >= 3);

    for boundary in 0..=op_count {
        let mut plan = audit(&f.env, &f.scope).unwrap().plan;
        plan.insert(boundary, refuses(&f)).unwrap();
        let error = apply::execute(&f.env, &plan).unwrap_err();
        assert!(matches!(error, CoreError::RolledBack { .. }));
        assert_eq!(
            hash::hash_tree(&f.project).unwrap(),
            before,
            "rollback after {boundary} ops must restore the project byte-identically"
        );
    }
    apply_now(&f);
    assert_eq!(drift_states(&f), vec![]);
}

/// An op that cannot run: it binds to nothing being at the manifest's
/// path, and the manifest is there.
#[allow(clippy::unwrap_used)]
fn refuses(f: &Fixture) -> apply::PlannedOp {
    let path = f.project.join("kendex.toml");
    assert!(path.is_file(), "the refusal needs a file to trip over");
    apply::PlannedOp {
        description: "refuse".into(),
        op: apply::Op::WriteFile {
            path,
            bytes: b"never written".to_vec(),
            pre: apply::Pre::Absent,
        },
    }
}

#[test]
fn invariant_8_one_writer_per_scope() {
    let f = fixture();
    let lock_path = f
        .env
        .scope_locks_dir()
        .join(format!("{}.lock", apply::scope_key(&f.scope)));
    fs::create_dir_all(f.env.scope_locks_dir()).unwrap();
    let file = fs::File::create(&lock_path).unwrap();
    let mut holder = fd_lock::RwLock::new(file);
    let _guard = holder.try_write().unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    let error = apply::execute(&f.env, &report.plan).unwrap_err();
    assert!(matches!(error, CoreError::ScopeBusy { .. }));
}

#[test]
fn legacy_v1_manifests_stay_byte_identical() {
    let f = fixture();
    let v1 = "[agent-skills]\nrust = [\"clippy\"]\n";
    fs::write(f.project.join("kendex.toml"), v1).unwrap();

    let error = ops::manifest_for_mutation(&f.env, &f.scope).unwrap_err();
    assert!(matches!(error, CoreError::LegacyManifest { .. }));
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(report.notes.iter().any(|n| n.contains("from version 1")));
    assert!(report.plan.is_empty());
    assert_eq!(
        fs::read_to_string(f.project.join("kendex.toml")).unwrap(),
        v1
    );
}

#[test]
fn plan_revalidates_before_each_mutation() {
    let f = fixture();
    let report = audit(&f.env, &f.scope).unwrap();
    // The world changes between plan and apply.
    fs::create_dir_all(f.project.join(".claude/agents")).unwrap();
    fs::write(agent_file(&f), "raced in").unwrap();
    let error = apply::execute(&f.env, &report.plan).unwrap_err();
    assert!(matches!(error, CoreError::RolledBack { .. }));
    assert_eq!(fs::read_to_string(agent_file(&f)).unwrap(), "raced in");
}
