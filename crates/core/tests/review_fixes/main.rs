//! One end-to-end test per confirmed correctness finding from the engine
//! review. Each fails on the behavior it replaced.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{
    DriftState, PlanOptions, adopt::adopt, audit, ops, persists_manifest, plan_scope,
};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind, Scope};

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    source: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn add_skill(source: &Path, name: &str) {
    put(
        &source.join(format!("skills/{name}/SKILL.md")),
        &format!("---\nname: {name}\ndescription: {name}\n---\n\n{name} body.\n"),
    );
}

/// A home with one path source carrying skill `gh` and agent `rust`.
fn world() -> World {
    let tmp = tempfile::tempdir();
    #[allow(clippy::unwrap_used)]
    let tmp = tmp.unwrap();
    let home = tmp.path().to_path_buf();
    let source = home.join("catalog");
    add_skill(&source, "gh");
    put(
        &source.join("agents/rust.md"),
        "---\nname: rust\ndescription: Rust engineer\nmodel: opus\nrole: engineer\n---\n\nBody.\n",
    );
    World {
        env: Env::fake(&home, FakeOs::Linux),
        home,
        source,
        _tmp: tmp,
    }
}

/// Write the scope's manifest: the shared preamble plus `body`.
fn declare(w: &World, scope: &Scope, body: &str) {
    put(
        &manifest::manifest_path(&w.env, scope),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{body}",
            source_path(&w.source)
        ),
    );
}

fn project(w: &World) -> Scope {
    Scope::Project {
        root: w.home.join("dev/app"),
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(w: &World, scope: &Scope) {
    let report = audit(&w.env, scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn loaded_manifest(w: &World, scope: &Scope) -> manifest::Manifest {
    manifest::load_for_mutation(&manifest::manifest_path(&w.env, scope))
        .unwrap()
        .unwrap()
}

fn has(report: &kendex_core::engine::EngineReport, name: &str, state: DriftState) -> bool {
    report
        .drift
        .iter()
        .any(|row| row.name == name && row.state == state)
}

#[test]
fn a_symlinked_disabled_sibling_is_a_conflict_not_a_write_target() {
    let w = world();
    let scope = project(&w);
    declare(&w, &scope, "[agents.rust]\nsource = \"cat\"\n");
    apply_now(&w, &scope);

    // The user's own file, outside every managed surface.
    let victim = w.home.join("notes/deploy.md");
    put(&victim, "precious");
    let agents = w.home.join("dev/app/.claude/agents");
    fs::remove_file(agents.join("rust.md")).unwrap();
    std::os::unix::fs::symlink(&victim, agents.join("rust.md.disabled")).unwrap();

    let report = audit(&w.env, &scope).unwrap();
    assert!(has(&report, "rust", DriftState::Conflict));
    apply::execute(&w.env, &report.plan).unwrap();

    assert_eq!(fs::read_to_string(&victim).unwrap(), "precious");
    assert!(agents.join("rust.md.disabled").is_symlink());
    assert!(!agents.join("rust.md").exists());
}

#[test]
fn a_file_recreated_between_plan_and_apply_aborts_the_rename() {
    let w = world();
    let scope = project(&w);
    declare(&w, &scope, "[agents.rust]\nsource = \"cat\"\n");
    apply_now(&w, &scope);
    let report = ops::toggle(&w.env, &scope, &["rust".to_owned()], None, false).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    // Re-enable is planned while the enabled name is free.
    let report = ops::toggle(&w.env, &scope, &["rust".to_owned()], None, true).unwrap();
    let agent = w.home.join("dev/app/.claude/agents/rust.md");
    put(&agent, "raced in");

    let error = apply::execute(&w.env, &report.plan).unwrap_err();
    assert!(matches!(error, CoreError::RolledBack { .. }));
    assert_eq!(fs::read_to_string(&agent).unwrap(), "raced in");
    assert!(
        w.home
            .join("dev/app/.claude/agents/rust.md.disabled")
            .is_file()
    );
}

#[test]
fn a_stale_plan_cannot_revert_a_newer_manifest() {
    let w = world();
    let scope = project(&w);
    declare(&w, &scope, "[skills.gh]\nsource = \"cat\"\n");
    apply_now(&w, &scope);
    add_skill(&w.source, "docs");

    // Planned, then held at a confirmation prompt while another writer runs.
    let stale = ops::add(
        &w.env,
        &scope,
        &ops::AddRequest {
            source: Some("cat".to_owned()),
            skills: vec!["docs".to_owned()],
            no_auto_skills: true,
            ..ops::AddRequest::default()
        },
    )
    .unwrap();
    let removal = ops::remove(&w.env, &scope, &["gh".to_owned()], None, false).unwrap();
    apply::execute(&w.env, &removal.plan).unwrap();

    let error = apply::execute(&w.env, &stale.plan).unwrap_err();
    assert!(matches!(error, CoreError::RolledBack { .. }));
    assert!(!loaded_manifest(&w, &scope).skills.contains_key("gh"));
    assert!(
        !load_lock(&lock_path(&w.env, &scope))
            .unwrap()
            .entries
            .values()
            .any(|entry| entry.name == "gh")
    );
}

#[test]
fn adoption_plans_never_mutate_at_plan_time() {
    let w = world();
    let scope = project(&w);
    declare(&w, &scope, "");
    let link = w.home.join("dev/app/.claude/skills/ghost");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(w.home.join("gone"), &link).unwrap();

    let claude = [HarnessId::Claude];
    let error = adopt(&w.env, &scope, ItemKind::Skill, "ghost", &claude).unwrap_err();
    assert!(matches!(error, CoreError::ItemNotInSource { .. }));
    assert!(link.is_symlink());
}

#[test]
fn rollback_removes_directories_the_apply_created() {
    let w = world();
    let scope = project(&w);
    declare(&w, &scope, "[skills.gh]\nsource = \"cat\"\n");

    let mut plan = audit(&w.env, &scope).unwrap().plan;
    // A last op that refuses: it binds to nothing being at the manifest's
    // path, and the manifest is there.
    let manifest = w.home.join("dev/app/kendex.toml");
    assert!(manifest.is_file(), "the refusal needs a file to trip over");
    let last = plan.ops.len();
    plan.insert(
        last,
        apply::PlannedOp {
            description: "refuse".into(),
            op: apply::Op::WriteFile {
                path: manifest,
                bytes: b"never written".to_vec(),
                pre: apply::Pre::Absent,
            },
        },
    )
    .unwrap();
    let error = apply::execute(&w.env, &plan).unwrap_err();

    assert!(matches!(error, CoreError::RolledBack { .. }));
    // Empty skeletons are what harness and project detection read as
    // "installed here" — a rolled-back apply may not leave them.
    assert!(!w.home.join("dev/app/.agents").exists());
    assert!(!w.home.join("dev/app/.claude").exists());
}

#[test]
fn reviewer_agents_merge_additions_into_the_key_that_is_read() {
    let w = world();
    let scope = project(&w);
    add_skill(&w.source, "dev");
    put(
        &w.source.join("agents/reviewer-rust.md"),
        "---\nname: reviewer-rust\ndescription: Rust reviewer\nmodel: opus\nrole: reviewer\n---\n\nBody.\n",
    );
    declare(
        &w,
        &scope,
        "[agents.reviewer-rust]\nsource = \"cat\"\n\n[agent-skills]\nrust = [\"dev\"]\n",
    );
    apply_now(&w, &scope);

    // Upstream gains a prefix-matching skill: it merges into the entry the
    // agent actually reads, never into a new one that shadows it.
    add_skill(&w.source, "rust-perf");
    apply_now(&w, &scope);

    let m = loaded_manifest(&w, &scope);
    assert_eq!(m.agent_skills["rust"], ["dev", "rust-perf"]);
    assert!(!m.agent_skills.contains_key("reviewer-rust"));
    let rendered =
        fs::read_to_string(w.home.join("dev/app/.claude/agents/reviewer-rust.md")).unwrap();
    assert!(rendered.contains("skills: dev, rust-perf"));
}

#[test]
fn narrowing_harnesses_orphans_the_stranded_installation() {
    let w = world();
    let scope = Scope::Global;
    declare(
        &w,
        &scope,
        "[skills.gh]\nsource = \"cat\"\nharnesses = [\"claude\", \"codex\"]\n",
    );
    apply_now(&w, &scope);
    let codex_link = w.home.join(".codex/skills/gh");
    assert!(codex_link.is_symlink());

    declare(
        &w,
        &scope,
        "[skills.gh]\nsource = \"cat\"\nharnesses = [\"claude\"]\n",
    );
    let report = audit(&w.env, &scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.harness == HarnessId::Codex && row.state == DriftState::Orphaned)
    );

    let report = plan_scope(
        &w.env,
        &scope,
        &loaded_manifest(&w, &scope),
        &load_lock(&lock_path(&w.env, &scope)).unwrap(),
        &PlanOptions {
            remove_orphans: true,
            removal_filter: None,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(!codex_link.is_symlink() && !codex_link.exists());
    assert!(w.home.join(".claude/skills/gh").is_symlink());
    assert_eq!(audit(&w.env, &scope).unwrap().drift, vec![]);
}

#[test]
fn an_unreadable_source_item_never_orphans_its_installation() {
    let w = world();
    let scope = project(&w);
    declare(&w, &scope, "[agents.rust]\nsource = \"cat\"\n");
    apply_now(&w, &scope);

    // Someone breaks the source file: kendex knows nothing about what the
    // declaration wants now, which is not the same as wanting nothing.
    put(&w.source.join("agents/rust.md"), "no frontmatter here\n");
    let report = plan_scope(
        &w.env,
        &scope,
        &loaded_manifest(&w, &scope),
        &load_lock(&lock_path(&w.env, &scope)).unwrap(),
        &PlanOptions {
            remove_orphans: true,
            removal_filter: None,
            ..PlanOptions::default()
        },
    )
    .unwrap();

    assert_eq!(report.drift, vec![]);
    assert!(report.plan.is_empty());
    assert!(w.home.join("dev/app/.claude/agents/rust.md").is_file());
}

#[test]
fn a_disabled_declaration_still_conflicts_with_an_unmanaged_enabled_file() {
    let w = world();
    let scope = project(&w);
    declare(
        &w,
        &scope,
        "[agents.rust]\nsource = \"cat\"\nenabled = false\n",
    );
    let handmade = w.home.join("dev/app/.claude/agents/rust.md");
    put(&handmade, "mine");

    let report = audit(&w.env, &scope).unwrap();
    assert!(has(&report, "rust", DriftState::Conflict));
    apply::execute(&w.env, &report.plan).unwrap();

    // The harness keeps loading the handmade file, so kendex may not report
    // the agent as cleanly disabled beside it.
    assert_eq!(fs::read_to_string(&handmade).unwrap(), "mine");
    assert!(
        !w.home
            .join("dev/app/.claude/agents/rust.md.disabled")
            .exists()
    );
}

#[test]
fn unmanaged_suppression_is_per_harness() {
    let w = world();
    let scope = Scope::Global;
    declare(&w, &scope, "[skills.gh]\nsource = \"cat\"\n");
    apply_now(&w, &scope);

    let handmade = w.home.join(".codex/skills/gh/SKILL.md");
    put(&handmade, "---\nname: gh\n---\nhandmade\n");
    let report = audit(&w.env, &scope).unwrap();

    assert!(report.drift.iter().any(|row| {
        row.name == "gh" && row.harness == HarnessId::Codex && row.state == DriftState::Unmanaged
    }));
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(
        fs::read_to_string(&handmade).unwrap(),
        "---\nname: gh\n---\nhandmade\n"
    );
}

#[test]
fn merged_manifests_do_not_leave_a_spurious_stale() {
    let w = world();
    let scope = project(&w);
    declare(
        &w,
        &scope,
        "[agents.rust]\nsource = \"cat\"\n\n[agent-skills]\nrust = [\"gh\"]\n",
    );
    apply_now(&w, &scope);

    add_skill(&w.source, "rust-perf");
    apply_now(&w, &scope);

    assert_eq!(
        loaded_manifest(&w, &scope).agent_skills["rust"],
        ["gh", "rust-perf"]
    );
    assert_eq!(audit(&w.env, &scope).unwrap().drift, vec![]);
}

#[test]
fn a_directory_at_a_file_target_is_a_conflict_not_a_retry_loop() {
    let w = world();
    let scope = project(&w);
    declare(
        &w,
        &scope,
        "[agents.rust]\nsource = \"cat\"\n\n[skills.gh]\nsource = \"cat\"\n",
    );
    fs::create_dir_all(w.home.join("dev/app/.claude/agents/rust.md")).unwrap();
    put(&w.home.join("dev/app/.agents/skills/gh"), "not a tree");

    let report = audit(&w.env, &scope).unwrap();
    assert!(has(&report, "rust", DriftState::Conflict));
    assert!(has(&report, "gh", DriftState::Conflict));
    // Nothing is planned against an occupied target, so the whole scope no
    // longer rolls back on every apply.
    assert!(report.plan.is_empty());
    apply::execute(&w.env, &report.plan).unwrap();
}

mod agent_skills;
mod roots;
