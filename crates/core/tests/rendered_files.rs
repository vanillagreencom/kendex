//! The lock names every file an apply wrote, by the path the repository
//! knows it under, with the hash `sha256sum` prints for it. This is the
//! record a reader with the repository and no kendex checks a rendered
//! file against; a path it cannot find or a hash it cannot reproduce is a
//! record it cannot use.
#![cfg(unix)]

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use sha2::{Digest, Sha256};

const GUARD: &str = "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: check shell commands\n# ---\nexit 0\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::create_dir_all(catalog.join("skills/hello/scripts")).unwrap();
    fs::write(catalog.join("hooks/guard.sh"), GUARD).unwrap();
    fs::write(
        catalog.join("skills/hello/SKILL.md"),
        "---\nname: hello\ndescription: says hello\n---\nSay hello.\n",
    )
    .unwrap();
    fs::write(catalog.join("skills/hello/scripts/run.sh"), "echo hello\n").unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.hello]\nsource = \"cat\"\n\n[hooks.guard]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn lock(f: &Fixture) -> serde_json::Value {
    serde_json::from_str(&fs::read_to_string(f.project.join(".kendex-lock.json")).unwrap()).unwrap()
}

fn sha256sum(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Every recorded path resolves under the project root to bytes whose
/// plain SHA-256 is the recorded hash, and every file the apply wrote is
/// recorded — the skill's whole tree, the hook's script.
#[test]
#[allow(clippy::unwrap_used)]
fn the_lock_names_each_written_file_with_the_hash_sha256sum_prints() {
    let f = fixture();
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();

    let lock = lock(&f);
    let entries = lock["entries"].as_object().unwrap();
    let files_of = |key: &str| -> Vec<(String, String)> {
        entries[key]["renderedFiles"]
            .as_object()
            .unwrap_or_else(|| panic!("{key} records no files: {}", entries[key]))
            .iter()
            .map(|(path, hash)| (path.clone(), hash.as_str().unwrap().to_owned()))
            .collect()
    };

    let skill = files_of("skill:hello:claude");
    assert_eq!(
        skill.iter().map(|(p, _)| p.as_str()).collect::<Vec<_>>(),
        vec![
            ".claude/skills/hello/SKILL.md",
            ".claude/skills/hello/scripts/run.sh"
        ],
        "one row per file, relative to the repository, never the link"
    );
    let hook = files_of("hook:guard:claude");
    assert_eq!(hook.len(), 1, "the script, not the settings file: {hook:?}");
    assert!(hook[0].0.ends_with("guard.sh"), "{hook:?}");

    for (path, hash) in skill.iter().chain(hook.iter()) {
        assert!(!path.starts_with('/'), "absolute path recorded: {path}");
        let on_disk = fs::read(f.project.join(path))
            .unwrap_or_else(|e| panic!("{path} recorded but not on disk: {e}"));
        assert_eq!(
            &sha256sum(&on_disk),
            hash,
            "{path}: hash is not sha256sum's"
        );
    }
}
