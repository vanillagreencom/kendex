//! A package name claimed from one marketplace cannot be silently rebound to
//! another — invariant 4 covers a name still only declared, not just one
//! already installed.
#![cfg(unix)]

use std::fs;

use kendex_core::engine::ops;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;

#[allow(clippy::unwrap_used)]
fn skill_catalog(dir: &std::path::Path, body: &str) {
    fs::create_dir_all(dir.join("skills/gh")).unwrap();
    fs::write(
        dir.join("skills/gh/SKILL.md"),
        format!("---\nname: gh\n---\n{body}\n"),
    )
    .unwrap();
}

/// A name declared from one source but not yet applied is claimed too: adding
/// it from another source is the same hard error, so a declaration cannot be
/// silently rebound to a second — possibly hostile — marketplace before it is
/// ever installed. This is the refusal the browse view already warns about.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_name_cannot_be_rebound_before_apply() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };

    let first = home.join("first");
    skill_catalog(&first, "the real one");
    let other = home.join("other");
    skill_catalog(&other, "impostor");
    // gh is declared from the first source but never applied — in the manifest,
    // not the lock.
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.first]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"first\"\n",
            first.display()
        ),
    )
    .unwrap();

    let error = ops::add(
        &env,
        &scope,
        &ops::AddRequest {
            source: Some(other.display().to_string()),
            skills: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap_err();
    assert!(
        matches!(&error, CoreError::SourceCollision { name, .. } if name == "gh"),
        "{error}"
    );
}
