//! The apply the user confirms must do what the preview said. A v0.1
//! manifest's first apply promises "Upgrade kendex.toml to the current
//! format" — this pins that the app's apply path actually writes it,
//! rather than re-planning from a mutation-normalized manifest that no
//! longer looks old.
#![cfg(unix)]

use std::fs;

use kendex_app::audit::{apply_scope, view};
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest::MANIFEST_SCHEMA;
use kendex_core::model::Scope;

const UPGRADE_OP: &str = "Upgrade kendex.toml to the current format";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    manifest_path: std::path::PathBuf,
}

#[allow(clippy::unwrap_used)]
fn v01_fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("skills/gh")).unwrap();
    fs::write(
        source.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: Work with GitHub.\n---\nBody.\n",
    )
    .unwrap();

    let manifest_path = project.join("kendex.toml");
    fs::write(
        &manifest_path,
        format!(
            "# my project setup\nschema = 1\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
            source.display()
        ),
    )
    .unwrap();
    fs::write(
        project.join(".kendex-lock.json"),
        "{\n  \"version\": 1,\n  \"entries\": {}\n}\n",
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        manifest_path,
        _tmp: tmp,
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn apply_performs_the_upgrade_the_preview_promised() {
    let f = v01_fixture();

    let before = view(&f.env, &f.scope);
    assert!(
        before.plan.iter().any(|op| op == UPGRADE_OP),
        "preview must promise the schema upgrade, got: {:?}",
        before.plan
    );

    let original = fs::read_to_string(&f.manifest_path).unwrap();
    apply_scope(&f.env, &f.scope, false).unwrap();

    let migrated = fs::read_to_string(&f.manifest_path).unwrap();
    assert_eq!(
        migrated,
        original.replacen("schema = 1", &format!("schema = {MANIFEST_SCHEMA}"), 1),
        "the upgrade must change the schema line and nothing else"
    );

    let after = view(&f.env, &f.scope);
    assert!(
        !after.plan.iter().any(|op| op == UPGRADE_OP),
        "a second look must not promise the upgrade again, got: {:?}",
        after.plan
    );
}

/// A manifest that vanished between the preview and the click is an error
/// said out loud, never a silent empty apply.
#[test]
#[allow(clippy::unwrap_used)]
fn applying_without_a_manifest_is_an_error() {
    let f = v01_fixture();
    fs::remove_file(&f.manifest_path).unwrap();
    let Err(error) = apply_scope(&f.env, &f.scope, false) else {
        panic!("applying without a manifest must error");
    };
    assert!(error.contains("no manifest"), "got: {error}");
}
