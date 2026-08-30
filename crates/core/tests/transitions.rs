//! A rendering one surface refuses never takes down a tree another surface
//! still reads.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply::{self, Op};
use kendex_core::engine::{DriftState, audit};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

#[allow(clippy::unwrap_used)]
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A description past Codex's 1024-character limit: Codex rejects the
/// skill outright, so the surface it reads refuses the rendering.
fn long_description() -> String {
    format!(
        "---\nname: big\ndescription: {}\n---\n\nBody.\n",
        "d".repeat(1025)
    )
}

#[allow(clippy::unwrap_used)]
fn apply_now(env: &Env, scope: &Scope) {
    let report = audit(env, scope).unwrap();
    apply::execute(env, &report.plan).unwrap();
}

fn trashes(report: &kendex_core::engine::EngineReport, path: &Path) -> usize {
    report
        .plan
        .ops
        .iter()
        .filter(|planned| matches!(&planned.op, Op::Trash { path: p, .. } if p == path))
        .count()
}

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    source: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    // Canonical up front: macOS reaches its temp dirs through a symlink,
    // and the engine hands back canonical paths.
    let home = tmp.path().canonicalize().unwrap();
    let source = home.join("catalog");
    put(
        &source.join("skills/big/SKILL.md"),
        "---\nname: big\ndescription: long\n---\n\n# Big\n\nIntro.\n",
    );
    World {
        env: Env::fake(&home, FakeOs::Linux),
        home,
        source,
        _tmp: tmp,
    }
}

/// Declare skill `big` for `harnesses` in the manifest at `manifest`.
fn declare(w: &World, manifest: &Path, harnesses: &str) {
    put(
        manifest,
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"symlink\"\n\n[skills.big]\nsource = \"cat\"\n",
            source_path(&w.source)
        ),
    );
}

/// Codex and Pi read one physical tree, so a rendering Codex refuses is
/// refused for Pi too — and the tree comes off disk exactly once. Planning
/// the same removal twice fails the second one and rolls the apply back,
/// leaving the scope unappliable until the catalog is hand-edited.
#[test]
#[allow(clippy::unwrap_used)]
fn two_tools_refusing_one_shared_tree_still_applies() {
    let w = world();
    let project = w.home.join("dev/app");
    declare(
        &w,
        &project.join("kendex.toml"),
        "\"claude\", \"codex\", \"pi\"",
    );
    let scope = Scope::Project {
        root: project.clone(),
    };
    apply_now(&w.env, &scope);

    put(&w.source.join("skills/big/SKILL.md"), &long_description());
    let report = audit(&w.env, &scope).unwrap();
    let shared = project.join(".agents/skills/big");
    assert_eq!(trashes(&report, &shared), 1, "{:?}", report.plan.ops);
    apply::execute(&w.env, &report.plan).unwrap();

    // The conflict is still reported, for both tools that share the tree.
    let after = audit(&w.env, &scope).unwrap();
    for harness in ["codex", "pi"] {
        assert!(
            after.drift.iter().any(|row| row.name == "big"
                && row.harness.name() == harness
                && row.state == DriftState::Conflict),
            "no conflict for {harness}: {:?}",
            after.drift
        );
    }
    // Claude takes any description, so it keeps the skill in a tree of its own.
    let claude = project.join(".claude/skills/big");
    assert!(!claude.is_symlink());
    assert_eq!(
        fs::read_to_string(claude.join("SKILL.md")).unwrap(),
        long_description()
    );
    assert!(!shared.exists());
    apply::execute(&w.env, &after.plan).unwrap();
}

/// Globally each tool links to one rendered tree. A refusal takes away the
/// refusing tool's own link and nothing else — trashing the shared tree
/// would uninstall the skill for every tool that still renders fine.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusal_keeps_the_tree_another_tool_still_reads() {
    let w = world();
    declare(&w, &w.env.global_manifest_file(), "\"claude\", \"codex\"");
    let scope = Scope::Global;
    apply_now(&w.env, &scope);

    let rendered = w.env.rendered_skills_dir().join("big");
    let claude = w.home.join(".claude/skills/big");
    let codex = w.home.join(".codex/skills/big");
    assert_eq!(fs::read_link(&claude).unwrap(), rendered);
    assert_eq!(fs::read_link(&codex).unwrap(), rendered);

    put(&w.source.join("skills/big/SKILL.md"), &long_description());
    let report = audit(&w.env, &scope).unwrap();
    assert_eq!(trashes(&report, &rendered), 0, "{:?}", report.plan.ops);
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(!codex.exists() && !codex.is_symlink());
    assert_eq!(fs::read_link(&claude).unwrap(), rendered);
    assert_eq!(
        fs::read_to_string(rendered.join("SKILL.md")).unwrap(),
        long_description()
    );
}

/// Two tools pointed at one directory read one physical skill folder, so
/// they also share the link into the rendered tree. Planning that link twice
/// fails the second op and rolls the whole apply back.
#[test]
#[allow(clippy::unwrap_used)]
fn two_tools_sharing_one_link_position_still_applies() {
    let w = world();
    let shared_root = w.home.join(".codex");
    let env = Env::fake(&w.home, FakeOs::Linux)
        .with_var("CODEX_HOME", &shared_root.display().to_string())
        .with_var("PI_CODING_AGENT_DIR", &shared_root.display().to_string());
    put(
        &env.global_manifest_file(),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"codex\", \"pi\"]\nmethod = \"symlink\"\n\n[skills.big]\nsource = \"cat\"\n",
            source_path(&w.source)
        ),
    );

    let scope = Scope::Global;
    let report = audit(&env, &scope).unwrap();
    apply::execute(&env, &report.plan).unwrap();

    let link = shared_root.join("skills/big");
    assert_eq!(
        fs::read_link(&link).unwrap(),
        env.rendered_skills_dir().join("big")
    );
    assert!(audit(&env, &scope).unwrap().drift.is_empty());
}
