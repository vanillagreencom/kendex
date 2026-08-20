//! A tool's copy of a skill moves between the shared tree and one of its
//! own as the skill grows past a byte cap and shrinks back, and a rendering
//! one surface refuses never takes down a tree another surface still reads.
#![cfg(unix)]

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

/// A skill body of roughly `sections` headed sections — small ones fit
/// Codex's 8192-byte cap, large ones split into `references/`.
fn sectioned(sections: usize) -> String {
    let mut body = String::from("---\nname: big\ndescription: long\n---\n\n# Big\n\nIntro.\n");
    for section in 0..sections {
        body.push_str(&format!(
            "\n## Section {section}\n\n{}\n",
            "prose ".repeat(60)
        ));
    }
    body
}

/// One fenced block spanning the cap: nothing can be cut without breaking
/// the fence, so the capped surface refuses the rendering outright.
fn one_huge_block() -> String {
    format!(
        "---\nname: big\ndescription: long\n---\n\n```text\n{}```\n",
        "sample line of a very long transcript\n".repeat(600)
    )
}

#[allow(clippy::unwrap_used)]
fn apply_now(env: &Env, scope: &Scope) {
    let report = audit(env, scope).unwrap();
    apply::execute(env, &report.plan, None).unwrap();
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
    put(&source.join("skills/big/SKILL.md"), &sectioned(5));
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
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"symlink\"\n\n[skills.big]\nsource = \"cat\"\n",
            w.source.display()
        ),
    );
}

/// Claude has no byte cap, so an oversized skill must give it a tree of its
/// own — even though its previous, matching rendering collapsed onto the
/// shared one through a link. Both directions of that move are ours to
/// make: the position is recorded as ours in the lock.
#[test]
#[allow(clippy::unwrap_used)]
fn a_tool_diverges_and_reconverges_without_ever_serving_the_split_body() {
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

    let shared = project.join(".agents/skills/big");
    let claude = project.join(".claude/skills/big");
    assert_eq!(fs::read_link(&claude).unwrap(), shared);

    // Grow it past Codex's cap. Claude must stop reading through the link,
    // or it serves the split head as if it were the whole skill.
    let grown = sectioned(40);
    assert!(grown.len() > 8192);
    put(&w.source.join("skills/big/SKILL.md"), &grown);
    apply_now(&w.env, &scope);

    assert!(!claude.is_symlink(), "claude keeps reading a shared tree");
    assert_eq!(fs::read_to_string(claude.join("SKILL.md")).unwrap(), grown);
    let head = fs::read_to_string(shared.join("SKILL.md")).unwrap();
    assert!(head.len() <= 8192);
    assert!(shared.join("references/details.md").is_file());
    assert!(audit(&w.env, &scope).unwrap().drift.is_empty());

    // Shrink it back: Claude's variant matches the shared one again, so it
    // collapses onto it rather than keeping a stale copy forever.
    let shrunk = sectioned(5);
    put(&w.source.join("skills/big/SKILL.md"), &shrunk);
    apply_now(&w.env, &scope);

    assert_eq!(fs::read_link(&claude).unwrap(), shared);
    assert_eq!(fs::read_to_string(shared.join("SKILL.md")).unwrap(), shrunk);
    assert!(!shared.join("references/details.md").exists());
    assert!(audit(&w.env, &scope).unwrap().drift.is_empty());
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

    put(&w.source.join("skills/big/SKILL.md"), &one_huge_block());
    let report = audit(&w.env, &scope).unwrap();
    let shared = project.join(".agents/skills/big");
    assert_eq!(trashes(&report, &shared), 1, "{:?}", report.plan.ops);
    apply::execute(&w.env, &report.plan, None).unwrap();

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
    // Claude has no cap, so it keeps the whole skill in a tree of its own.
    let claude = project.join(".claude/skills/big");
    assert!(!claude.is_symlink());
    assert_eq!(
        fs::read_to_string(claude.join("SKILL.md")).unwrap(),
        one_huge_block()
    );
    assert!(!shared.exists());
    apply::execute(&w.env, &after.plan, None).unwrap();
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

    put(&w.source.join("skills/big/SKILL.md"), &one_huge_block());
    let report = audit(&w.env, &scope).unwrap();
    assert_eq!(trashes(&report, &rendered), 0, "{:?}", report.plan.ops);
    apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(!codex.exists() && !codex.is_symlink());
    assert_eq!(fs::read_link(&claude).unwrap(), rendered);
    assert_eq!(
        fs::read_to_string(rendered.join("SKILL.md")).unwrap(),
        one_huge_block()
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
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"codex\", \"pi\"]\nmethod = \"symlink\"\n\n[skills.big]\nsource = \"cat\"\n",
            w.source.display()
        ),
    );

    let scope = Scope::Global;
    let report = audit(&env, &scope).unwrap();
    apply::execute(&env, &report.plan, None).unwrap();

    let link = shared_root.join("skills/big");
    assert_eq!(
        fs::read_link(&link).unwrap(),
        env.rendered_skills_dir().join("big")
    );
    assert!(audit(&env, &scope).unwrap().drift.is_empty());
}
