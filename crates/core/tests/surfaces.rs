//! The surface model: a physical surface consumed by several harnesses
//! carries exactly one variant; other surfaces link to it while their bytes
//! match and get their own tree when they diverge.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

#[test]
#[allow(clippy::unwrap_used)]
fn codex_and_pi_share_one_project_variant_and_claude_links_while_equal() {
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
        "---\nname: gh\ndescription: github\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\", \"codex\", \"pi\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();

    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = audit(&env, &scope).unwrap();
    apply::execute(&env, &report.plan).unwrap();

    // Codex and Pi read the same physical tree — one variant, no links.
    let shared = project.join(".agents/skills/gh");
    assert!(shared.join("SKILL.md").is_file());
    assert!(!shared.is_symlink());
    // Claude's variant currently matches, so it deduplicates onto the
    // shared tree through a link rather than a second copy.
    let claude = project.join(".claude/skills/gh");
    assert_eq!(
        fs::read_link(&claude).unwrap(),
        std::path::Path::new("../../.agents/skills/gh")
    );
    assert_eq!(
        claude.canonicalize().unwrap(),
        shared.canonicalize().unwrap()
    );

    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    for key in ["skill:gh:claude", "skill:gh:codex", "skill:gh:pi"] {
        assert!(lock["entries"].get(key).is_some(), "{key} missing");
    }
    assert!(audit(&env, &scope).unwrap().drift.is_empty());
}

/// No harness caps a skill body, so a large skill renders once and every
/// surface reads the same bytes: Codex and Pi share the tree and Claude
/// links to it, with nothing cut into `references/` for anyone.
#[test]
#[allow(clippy::unwrap_used)]
fn a_large_skill_is_one_tree_every_surface_links_to() {
    let tmp = tempfile::tempdir().unwrap();
    // Canonical up front: macOS reaches its temp dirs through a symlink,
    // and the engine hands back canonical paths.
    let home = tmp.path().canonicalize().unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("skills/big")).unwrap();
    let mut body = String::from("---\nname: big\ndescription: long\n---\n\n# Big\n\nIntro.\n");
    for section in 0..40 {
        body.push_str(&format!(
            "\n## Section {section}\n\n{}\n",
            "prose ".repeat(80)
        ));
    }
    fs::write(source.join("skills/big/SKILL.md"), &body).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\", \"codex\", \"pi\"]\nmethod = \"symlink\"\n\n[skills.big]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();

    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = audit(&env, &scope).unwrap();
    assert!(
        report.warnings.iter().all(|w| w.name != "big"),
        "nothing to warn about: {:?}",
        report.warnings
    );
    apply::execute(&env, &report.plan).unwrap();

    let shared = project.join(".agents/skills/big");
    assert_eq!(fs::read_to_string(shared.join("SKILL.md")).unwrap(), body);
    assert!(!shared.join("references").exists());

    let claude = project.join(".claude/skills/big");
    assert!(claude.is_symlink(), "Claude links to the shared tree");
    assert_eq!(fs::read_to_string(claude.join("SKILL.md")).unwrap(), body);

    assert!(audit(&env, &scope).unwrap().drift.is_empty());
}
