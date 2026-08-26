//! A v1 lock (bare-name keys, `harnesses` array, no singular `harness`) must
//! not crash the audit with a raw serde error, and a damaged or
//! future-version lock must not take down the rest of a multi-scope audit —
//! the caller sees it as data (a note, or a distinctly typed error) instead.
#![cfg(unix)]

use std::fs;

use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    lock_path: std::path::PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    fs::write(
        project.join("kendex.toml"),
        "schema = 1\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
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

/// The exact shape a real v1 lock carries: entries keyed by bare name, a
/// `harnesses` array, no singular `harness` field.
const V1_LOCK: &str = r#"{
  "version": 1,
  "entries": {
    "block-bare-cd": {
      "name": "block-bare-cd",
      "kind": "hook",
      "source": "vanillagreencom/kendex",
      "source_repo": "vanillagreencom/kendex",
      "harnesses": ["claude-code", "codex"],
      "method": "symlink",
      "installed_at": "2026-08-14T09:26:55Z",
      "source_hash": "9653b4a3922dfbe3"
    }
  }
}"#;

#[test]
#[allow(clippy::unwrap_used)]
fn a_v1_lock_audits_read_only_with_a_note_instead_of_a_parse_error() {
    let f = fixture();
    fs::write(&f.lock_path, V1_LOCK).unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report.notes.iter().any(|n| n.contains("from version 1")),
        "expected a v1-lock note, got: {:?}",
        report.notes
    );
    assert!(report.plan.ops.is_empty(), "nothing is planned read-only");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_corrupt_lock_is_a_distinct_error_not_a_v1_note() {
    let f = fixture();
    fs::write(&f.lock_path, "{not json").unwrap();

    assert!(matches!(
        audit(&f.env, &f.scope),
        Err(CoreError::LockCorrupt { .. })
    ));
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_future_version_lock_refuses_to_load_with_its_own_error() {
    let f = fixture();
    fs::write(&f.lock_path, r#"{"version":99,"entries":{}}"#).unwrap();

    assert!(matches!(
        audit(&f.env, &f.scope),
        Err(CoreError::SchemaTooNew { found: 99, .. })
    ));
}
