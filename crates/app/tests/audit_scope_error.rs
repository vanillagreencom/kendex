//! One scope's unreadable lock must not fail the whole audit. `view` (what
//! `audit_all` maps over per scope) carries a v1 lock as a plain-words note
//! and a damaged lock as a structured, typed error — never a bubbled-up
//! panic or string that would blank every other registered scope.
#![cfg(unix)]

use std::fs;

use kendex_app::audit::{ScopeErrorKind, view};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    lock_path: std::path::PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture(name: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev").join(name);
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 2\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
    )
    .unwrap();
    let lock_path = project.join(".kendex-lock.json");
    Fixture {
        env,
        scope: Scope::Project { root: project },
        lock_path,
        _tmp: tmp,
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_v1_lock_scope_audits_successfully_with_a_note() {
    let f = fixture("app");
    fs::write(
        &f.lock_path,
        r#"{"version":1,"entries":{"gh":{"name":"gh","kind":"skill","source":"kendex","source_repo":"vanillagreencom/kendex","harnesses":["claude-code"],"method":"symlink","installed_at":"2026-01-01T00:00:00Z","source_hash":"abc"}}}"#,
    )
    .unwrap();

    let result = view(&f.env, &f.scope);
    assert!(result.error.is_none(), "a v1 lock is not a scope error");
    assert!(
        result.notes.iter().any(|n| n.contains("from version 1")),
        "expected a v1-lock note, got: {:?}",
        result.notes
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_corrupt_lock_scope_carries_a_structured_error_and_leaves_others_alone() {
    let corrupt = fixture("broken");
    fs::write(&corrupt.lock_path, "{not json").unwrap();
    let healthy = fixture("fine");

    let broken_view = view(&corrupt.env, &corrupt.scope);
    let error = broken_view.error.expect("a damaged lock is a scope error");
    assert!(matches!(error.kind, ScopeErrorKind::LockCorrupt));
    assert!(broken_view.drift.is_empty());
    assert!(broken_view.plan.is_empty());

    // A second, unrelated scope's own view is unaffected — one scope's
    // failure never propagates past its own AuditView.
    let healthy_view = view(&healthy.env, &healthy.scope);
    assert!(healthy_view.error.is_none());
}
