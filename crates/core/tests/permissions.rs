//! Permission intent end-to-end: parse → merge → render through a real
//! plan, including the refusal path on a harness that cannot express an
//! allowlist.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{DriftState, audit};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("agents")).unwrap();
    fs::write(
        source.join("agents/rust.md"),
        "---\nname: rust\ndescription: Rust engineer\nmodel: opus\nrole: engineer\n---\n\nBody.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\", \"pi\"]\nmethod = \"symlink\"\n\n[agents.rust]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        source,
        _tmp: tmp,
    }
}

/// A tool allowlist must survive parse → merge → render, and a harness that
/// cannot express it (Pi) must refuse: conflict row, no fresh artifact, and
/// the previously-installed wider rendering leaves the disk on apply.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refused_rendering_is_a_conflict_and_removes_the_wide_artifact() {
    let f = fixture();
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    let pi_agent = f.project.join(".pi/agents/rust.md");
    assert!(pi_agent.is_file());

    // Upstream narrows the agent to a read-only allowlist.
    fs::write(
        f.source.join("agents/rust.md"),
        "---\nname: rust\ndescription: Rust reviewer\ntools: Read, Grep\n---\n\nBody.\n",
    )
    .unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    let conflict = report
        .drift
        .iter()
        .find(|row| row.name == "rust" && row.state == DriftState::Conflict)
        .expect("pi refusal is a conflict row");
    assert!(conflict.detail.contains("widen"));
    assert!(conflict.detail.contains("trash"));

    apply::execute(&f.env, &report.plan).unwrap();
    assert!(
        !pi_agent.exists(),
        "the wide pi rendering must come off disk"
    );
    let claude = fs::read_to_string(f.project.join(".claude/agents/rust.md")).unwrap();
    assert!(claude.contains("tools: Read, Grep"));
    // The refusal stays a conflict row (still declared for pi), never an
    // orphan, and never resurrects the artifact.
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .all(|row| row.state != DriftState::Orphaned)
    );
    assert!(!pi_agent.exists());
}
