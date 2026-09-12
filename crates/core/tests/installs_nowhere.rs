//! An install that would land nowhere is refused before the manifest gains
//! a declaration. Leaving the tools to the scope's defaults on a machine
//! with no tool is the case that used to report success over a plan that
//! wrote nothing; one detected tool is what makes the same request land.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::engine::ops;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::{HarnessId, Scope};
use kendex_core::{apply, manifest};

/// A home with no manifest and no tool, beside a path catalog holding one
/// skill. The personal scope's first install seeds its manifest from what
/// the machine has.
#[allow(clippy::unwrap_used)]
fn fixture() -> (tempfile::TempDir, Env, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/gh")).unwrap();
    fs::write(
        catalog.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github\n---\n\nBody.\n",
    )
    .unwrap();
    (tmp, env, catalog)
}

/// The untouched picker: the request names no tool and leaves the choice
/// to the scope.
fn untouched(catalog: &Path) -> ops::AddRequest {
    ops::AddRequest {
        source: Some(catalog.display().to_string()),
        skills: vec!["gh".into()],
        ..ops::AddRequest::default()
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn no_tool_on_the_machine_refuses_before_the_manifest_gains_a_declaration() {
    let (_tmp, env, catalog) = fixture();

    let error = ops::add(&env, &Scope::Global, &untouched(&catalog)).unwrap_err();

    assert!(
        matches!(error, CoreError::InstallsNowhere { .. }),
        "expected the installs-nowhere refusal, got {error:?}"
    );
    assert!(
        !manifest::manifest_path(&env, &Scope::Global).exists(),
        "the refused install left a manifest behind"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn one_detected_tool_takes_the_same_request() {
    let (_tmp, env, catalog) = fixture();
    fs::create_dir_all(env.home.join(".claude")).unwrap();

    let report = ops::add(&env, &Scope::Global, &untouched(&catalog)).unwrap();
    apply::execute(&env, &report.plan).unwrap();

    let written = manifest::load_for_mutation(&manifest::manifest_path(&env, &Scope::Global))
        .unwrap()
        .unwrap();
    assert_eq!(written.install.harnesses, [HarnessId::Claude]);
    assert!(written.skills.contains_key("gh"));
    assert!(env.home.join(".claude/skills/gh/SKILL.md").exists());
}
