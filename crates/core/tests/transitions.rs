//! Tools that share a skill tree plan each position once.
#![cfg(unix)]

use crate::test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

#[allow(clippy::unwrap_used)]
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

struct World {
    _tmp: tempfile::TempDir,
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
        home,
        source,
        _tmp: tmp,
    }
}

/// Two tools pointed at one directory read one physical skill folder, and
/// globally they read the shared tree as well, so the pair is one surface
/// group holding one tree. Planning that position twice would fail the
/// second op and roll the whole apply back.
#[test]
#[allow(clippy::unwrap_used)]
fn two_tools_sharing_one_root_still_applies() {
    let w = world();
    let shared_root = w.home.join(".codex");
    let env = Env::fake(&w.home, FakeOs::Linux)
        .with_var("CODEX_HOME", &shared_root.display().to_string())
        .with_var("PI_CODING_AGENT_DIR", &shared_root.display().to_string());
    put(
        &env.global_manifest_file(),
        &format!(
            "schema = 7\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"codex\", \"pi\"]\nmethod = \"symlink\"\n\n[skills.big]\nsource = \"cat\"\n",
            source_path(&w.source)
        ),
    );

    let scope = Scope::Global;
    let report = audit(&env, &scope).unwrap();
    apply::execute(&env, &report.plan).unwrap();

    let shared = env.global_skills_dir().join("big");
    assert!(shared.join("SKILL.md").is_file());
    assert!(!shared.is_symlink());
    // Both tools read the shared tree, so neither gets a link of its own.
    assert!(!shared_root.join("skills/big").exists());
    assert!(audit(&env, &scope).unwrap().drift.is_empty());
}
