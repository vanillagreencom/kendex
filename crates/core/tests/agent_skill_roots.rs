//! The path an agent is told to read a required skill from is the place
//! that skill's own delivery wrote — proved against what the install put
//! on disk, not against a second derivation of the same rule.
//!
//! A copy is written in the tool's own directory, which four adapters let
//! a variable relocate, so the relocated case is the one under test: it is
//! the only one where naming a literal and asking the surfaces give
//! different answers.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::Path;

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

const AGENT: &str = "---\nname: rust\ndescription: Rust engineer\nrole: engineer\n---\nBody.\n";
const SKILL: &str = "---\nname: gh\ndescription: github\n---\nBody.\n";

/// A catalog carrying one agent that requires one skill, installed for
/// Codex at `scope` under `method`, with `vars` applied to the fixture env.
#[allow(clippy::unwrap_used)]
fn installed(home: &Path, method: &str, vars: &[(&str, String)]) -> (Env, String) {
    let mut env = Env::fake(home, FakeOs::Linux);
    for (key, value) in vars {
        env = env.with_var(key, value);
    }
    let source = home.join("catalog");
    fs::create_dir_all(source.join("skills/gh")).unwrap();
    fs::write(source.join("skills/gh/SKILL.md"), SKILL).unwrap();
    fs::create_dir_all(source.join("agents")).unwrap();
    fs::write(source.join("agents/rust.md"), AGENT).unwrap();
    let manifest = env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"codex\"]\nmethod = \"{method}\"\n\n[skills.gh]\nsource = \"cat\"\n\n[agents.rust]\nsource = \"cat\"\n\n[agent-skills]\nrust = [\"gh\"]\n",
            source_path(&source)
        ),
    )
    .unwrap();

    let report = audit(&env, &Scope::Global).unwrap();
    apply::execute(&env, &report.plan).unwrap();
    let root = kendex_core::harness::adapter(kendex_core::model::HarnessId::Codex)
        .default_global_root(&env);
    (
        env,
        fs::read_to_string(root.join("agents/rust.toml")).unwrap(),
    )
}

/// A copy for a harness whose root a variable moved: the tree lands under
/// the relocated root, and the agent is told to read it there. Naming the
/// unrelocated literal is the failure this pins.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copied_skill_is_read_from_the_relocated_root_the_copy_wrote() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let elsewhere = home.join("alt/codex");
    let (_env, agent) = installed(
        &home,
        "copy",
        &[("CODEX_HOME", elsewhere.display().to_string())],
    );

    assert!(elsewhere.join("skills/gh/SKILL.md").is_file());
    assert!(!home.join(".codex/skills/gh").exists());
    assert!(!home.join(".agents/skills/gh").exists());
    assert!(
        agent.contains("- gh: ~/alt/codex/skills/gh/SKILL.md"),
        "the agent reads the copy where it landed: {agent}"
    );
}

/// The must-fail pair. The same declaration delivered the other way writes
/// the shared tree instead, and the agent is told that place — so the
/// assertion above holds because the delivery and the root were read, not
/// because every install names one directory.
#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_skill_is_read_from_the_shared_tree_the_link_wrote() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let elsewhere = home.join("alt/codex");
    let (_env, agent) = installed(
        &home,
        "symlink",
        &[("CODEX_HOME", elsewhere.display().to_string())],
    );

    assert!(home.join(".agents/skills/gh/SKILL.md").is_file());
    assert!(!elsewhere.join("skills/gh").exists());
    assert!(
        agent.contains("- gh: ~/.agents/skills/gh/SKILL.md"),
        "the agent reads the shared tree: {agent}"
    );
}
