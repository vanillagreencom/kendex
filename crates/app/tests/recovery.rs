//! Launch recovery: a journal a crash left pending in any known scope is
//! rolled back before the app shows anything.
#![cfg(unix)]

use std::fs;

use kendex_core::apply::{journal, scope_key};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

#[test]
#[allow(clippy::unwrap_used)]
fn launch_recovery_rolls_back_pending_journals_in_registered_projects() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("dev/app");
    fs::create_dir_all(&project).unwrap();
    kendex_core::settings::register_project(&env, &project).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };

    // Stage what a crash mid-apply leaves behind: a pre-image journal plus
    // a mutation that never got committed.
    let victim = project.join("generated.md");
    fs::write(&victim, "original").unwrap();
    let dir = journal::journal_dir_for(&env.journal_dir(), &scope_key(&scope));
    journal::write(&dir, std::slice::from_ref(&victim)).unwrap();
    fs::write(&victim, "half-written").unwrap();
    assert!(journal::pending(&dir));

    let messages = kendex_app::recovery::recover_on_launch(&env);
    assert_eq!(fs::read_to_string(&victim).unwrap(), "original");
    assert!(!journal::pending(&dir));
    assert!(
        messages.iter().any(|m| m.contains("recovered")),
        "{messages:?}"
    );

    // Nothing pending: the next launch is silent.
    assert!(kendex_app::recovery::recover_on_launch(&env).is_empty());
}
