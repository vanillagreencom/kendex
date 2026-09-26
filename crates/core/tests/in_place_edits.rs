//! An in-place skill's tree is its source. kendex writes one thing into it,
//! the project-instructions block in `SKILL.md`, and holds the harness links
//! and the record; nothing else of the tree is compared, recorded or
//! rewritten, so an edit to it changes nothing kendex says or records.
//!
//! The must-fail control for the edit surface is the engine before this
//! one: an edit moved the recorded source hash, so the plan raised a stale
//! row and the record it wrote differed from the committed one.
#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::drift;
use kendex_core::engine::{DriftState, PlanOptions, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

const AUTHORED: &str = "---\nname: deploy\ndescription: ship it\n---\nOwned source.\n";
const REFERENCE: &str = "step one\n";

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    project: PathBuf,
    scope: Scope,
}

impl World {
    fn source(&self) -> PathBuf {
        self.project.join(".agents/skills/deploy")
    }

    fn skill_file(&self) -> PathBuf {
        self.source().join("SKILL.md")
    }

    fn lock_path(&self) -> PathBuf {
        kendex_core::lock::lock_path(&self.env, &self.scope)
    }

    #[allow(clippy::unwrap_used)]
    fn declare(&self, instructions: Option<&str>) {
        let instructions = instructions
            .map(|text| format!("[skill-instructions]\nall = \"{text}\"\n\n"))
            .unwrap_or_default();
        fs::write(
            self.project.join("kendex.toml"),
            format!(
                "schema = 6\n\n{instructions}[install]\nharnesses = [\"claude\", \"codex\", \"pi\"]\nmethod = \"symlink\"\n\n[skills.deploy]\nsource = \"in-place\"\n"
            ),
        )
        .unwrap();
    }

    #[allow(clippy::unwrap_used)]
    fn apply(&self) -> kendex_core::engine::EngineReport {
        let report = plan_apply(&self.env, &self.scope, &PlanOptions::default()).unwrap();
        apply::execute(&self.env, &report.plan).unwrap();
        report
    }

    #[allow(clippy::unwrap_used)]
    fn read(&self, path: &Path) -> String {
        fs::read_to_string(path).unwrap()
    }

    fn check_text(&self) -> String {
        drift::report::render_plain(&drift::report::check(
            &self.env,
            std::slice::from_ref(&self.scope),
        ))
    }
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("app");
    let source = project.join(".agents/skills/deploy");
    fs::create_dir_all(&source).unwrap();
    fs::write(source.join("SKILL.md"), AUTHORED).unwrap();
    fs::write(source.join("reference.md"), REFERENCE).unwrap();
    let world = World {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    };
    world.declare(Some("shared rule"));
    world
}

fn deploy_rows(report: &kendex_core::engine::EngineReport) -> Vec<(DriftState, String)> {
    report
        .drift
        .iter()
        .filter(|row| row.name == "deploy")
        .map(|row| (row.state, row.detail.clone()))
        .collect()
}

/// Apply writes the block into `SKILL.md` and touches no other byte of the
/// tree; the record holds the links alone, with no rendered hash, because
/// kendex wrote no render of the tree.
#[test]
#[allow(clippy::unwrap_used)]
fn apply_writes_the_instructions_block_and_nothing_else() {
    let world = world();

    world.apply();

    let skill = world.read(&world.skill_file());
    assert_eq!(
        skill,
        kendex_core::render::skill::inject_instructions(
            AUTHORED,
            Some(
                "<!-- kendex:shared-instructions:start -->\nshared rule\n<!-- kendex:shared-instructions:end -->"
            )
        ),
        "{skill}"
    );
    assert!(skill.ends_with("Owned source.\n"), "{skill}");
    assert_eq!(world.read(&world.source().join("reference.md")), REFERENCE);
    assert!(world.project.join(".claude/skills/deploy").is_symlink());
    let lock = kendex_core::lock::load(&world.lock_path()).unwrap();
    let entries: Vec<_> = lock
        .entries
        .values()
        .filter(|entry| entry.name == "deploy")
        .collect();
    assert_eq!(entries.len(), 3, "{:?}", lock.entries.keys());
    for entry in entries {
        assert_eq!(entry.rendered_hash, None, "{}", entry.harness.name());
        assert!(
            entry
                .emitted
                .as_ref()
                .is_none_or(|emitted| !emitted.paths.contains(&world.source())),
            "{}: {:?}",
            entry.harness.name(),
            entry.emitted
        );
    }
    assert_eq!(world.check_text(), "");
}

/// An edit to the tree is the source changing, which kendex neither
/// reports nor records: the next plan raises no row for the skill, writes
/// nothing, and leaves the committed record byte for byte.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_to_the_tree_raises_no_row_and_moves_no_record() {
    let world = world();
    world.apply();
    let recorded = world.read(&world.lock_path());
    let mut skill = world.read(&world.skill_file());
    skill.push_str("Another edit.\n");
    fs::write(world.skill_file(), &skill).unwrap();
    fs::write(world.source().join("reference.md"), "step one\nstep two\n").unwrap();

    let report = world.apply();

    assert_eq!(deploy_rows(&report), Vec::new());
    assert!(report.plan.ops.is_empty(), "{:?}", report.plan.ops);
    assert_eq!(world.read(&world.lock_path()), recorded);
    assert_eq!(world.read(&world.skill_file()), skill);
    let lock = kendex_core::lock::load(&world.lock_path()).unwrap();
    let standing = kendex_core::attest::record(&world.env, &world.scope, &lock, &report)
        .unwrap()
        .unwrap();
    assert_eq!(standing.problems, Vec::<String>::new());
    assert_eq!(world.check_text(), "");
}

/// A changed instruction is the one input kendex records: the plan says
/// the block is stale, rewrites `SKILL.md` with the new block and keeps
/// every authored byte around it, edits included; the other files are not
/// touched. Instructions taken away strip the block, leaving the authored
/// text exactly.
#[test]
#[allow(clippy::unwrap_used)]
fn a_changed_instruction_rewrites_the_block_alone() {
    let world = world();
    world.apply();
    let mut skill = world.read(&world.skill_file());
    skill.push_str("Another edit.\n");
    fs::write(world.skill_file(), &skill).unwrap();
    world.declare(Some("new rule"));

    let report = world.apply();

    assert_eq!(
        deploy_rows(&report),
        vec![
            (
                DriftState::Stale,
                "its project-instructions block is not current".to_owned()
            );
            3
        ]
    );
    let rewritten = world.read(&world.skill_file());
    assert!(rewritten.contains("new rule"), "{rewritten}");
    assert!(!rewritten.contains("shared rule"), "{rewritten}");
    assert!(
        rewritten.ends_with("Owned source.\nAnother edit.\n"),
        "{rewritten}"
    );
    assert_eq!(world.read(&world.source().join("reference.md")), REFERENCE);

    world.declare(None);
    world.apply();
    assert_eq!(
        world.read(&world.skill_file()),
        format!("{AUTHORED}Another edit.\n")
    );
    assert_eq!(world.check_text(), "");
}
