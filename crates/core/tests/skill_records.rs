//! What the lock keeps about where a skill landed, and what that buys.
//!
//! A tool's skill directory moves between kendex versions. A pass that
//! derived the place again would name one this install never wrote, and
//! the link it did write would then outlive every refresh — absolute,
//! and committed under the shared posture. The record is where a later
//! pass finds it.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};
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
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    // Resolved: the lock records the paths an install wrote, and the
    // engine resolves the scope root before writing any of them. On macOS
    // the temp directory is reached through `/var -> private/var`, so an
    // unresolved fixture path never equals what the record holds.
    let home = tmp.path().canonicalize().unwrap();
    let project = home.join("dev/app");
    let source = home.join("catalog");
    put(
        &source.join("skills/ship/SKILL.md"),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
    );
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        source,
        _tmp: tmp,
    }
}

fn declare(f: &Fixture, harnesses: &str) {
    put(
        &f.project.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"symlink\"\n\n[skills.ship]\nsource = \"cat\"\n",
            source_path(&f.source)
        ),
    );
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn settled(f: &Fixture) -> bool {
    let report = audit(&f.env, &f.scope).unwrap();
    report.plan.ops.is_empty()
        && !report
            .drift
            .iter()
            .any(|row| row.state == DriftState::Conflict)
}

#[allow(clippy::unwrap_used)]
fn recorded_paths(f: &Fixture, key: &str) -> Vec<PathBuf> {
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(f.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    lock["entries"][key]["emitted"]["paths"]
        .as_array()
        .map(|paths| {
            paths
                .iter()
                .map(|p| PathBuf::from(p.as_str().unwrap()))
                .collect()
        })
        .unwrap_or_default()
}

/// The record a kendex from this version on writes, after a layout change:
/// a link at a place the current render never produces, recorded by the
/// install that wrote it.
#[allow(clippy::unwrap_used)]
fn as_written_under_the_old_layout(f: &Fixture, key: &str, link: &Path) {
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(f.project.join(".agents/skills/ship"), link).unwrap();
    let path = f.project.join(".kendex-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    lock["entries"][key]["emitted"]["paths"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::Value::String(link.display().to_string()));
    fs::write(&path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
}

/// A refresh takes the link the desired state stopped producing, and only
/// that: the tree and the link it still produces stay. Without the record,
/// the pass derives today's link and never learns of the old one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_the_render_stopped_producing_comes_off_by_its_record() {
    let f = fixture();
    declare(&f, "\"claude\"");
    apply_now(&f);
    let shared = f.project.join(".agents/skills/ship");
    let link = f.project.join(".claude/skills/ship");
    assert_eq!(
        recorded_paths(&f, "skill:ship:claude"),
        vec![shared.clone(), link.clone()],
        "the record names the tree and the link this install wrote"
    );

    let old = f.project.join(".claude/rules/ship");
    as_written_under_the_old_layout(&f, "skill:ship:claude", &old);
    apply_now(&f);

    assert!(
        !old.is_symlink(),
        "the link nothing produces anymore is still on disk"
    );
    assert!(link.is_symlink() && shared.is_dir());
    assert_eq!(recorded_paths(&f, "skill:ship:claude"), vec![shared, link]);
    assert!(settled(&f));
}

/// An install nothing declares anymore comes off by the paths it recorded,
/// the shared tree another tool still reads excepted.
#[test]
#[allow(clippy::unwrap_used)]
fn an_orphaned_install_comes_off_by_the_paths_it_recorded() {
    let f = fixture();
    declare(&f, "\"claude\", \"codex\"");
    apply_now(&f);
    let old = f.project.join(".claude/rules/ship");
    as_written_under_the_old_layout(&f, "skill:ship:claude", &old);

    declare(&f, "\"codex\"");
    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            remove_orphans: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    assert!(
        !old.is_symlink(),
        "the link nothing produces anymore is still on disk"
    );
    assert!(!f.project.join(".claude/skills/ship").is_symlink());
    assert!(f.project.join(".agents/skills/ship").is_dir());
    assert!(settled(&f));
}

/// An install this pass holds plans no replacement, so what it recorded
/// is still what runs. Judged by the render instead, the old link came off
/// while the tree it connected stayed held, and nothing was written after.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_install_keeps_the_link_it_recorded() {
    let f = fixture();
    declare(&f, "\"claude\"");
    apply_now(&f);
    let old = f.project.join(".claude/rules/ship");
    as_written_under_the_old_layout(&f, "skill:ship:claude", &old);
    fs::write(
        f.project.join(".agents/skills/ship/SKILL.md"),
        "edited by hand\n",
    )
    .unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.state == DriftState::Conflict),
        "the edit holds the install: {:?}",
        report.drift
    );
    apply::execute(&f.env, &report.plan).unwrap();

    assert!(
        old.is_symlink(),
        "the held install's link came off with nothing replacing it"
    );
}
