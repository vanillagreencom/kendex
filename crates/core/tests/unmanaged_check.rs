//! What the session check says about a declaration whose files are already
//! on disk. The check reads the manifest, the lock and a stat — so what it
//! may claim is exactly what those prove: that nothing is installed and
//! that something is already at the position. Which way out fits needs the
//! render it cannot build, so the remedy is the plan that decides.
#![cfg(unix)]

use std::fs;
use std::path::PathBuf;

use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use kendex_core::{apply, drift};

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    scope: Scope,
}

/// A catalog offering one of each kind the check can stat for, and a
/// project declaring all three.
#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let catalog = home.join("catalog");
    fs::create_dir_all(&catalog).unwrap();
    // The declared layout, which is what a command is read through.
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/scout.md"),
        "---\nname: scout\ndescription: looks around\n---\nUpstream.\n",
    )
    .unwrap();
    fs::create_dir_all(catalog.join("commands")).unwrap();
    fs::write(
        catalog.join("commands/ship.md"),
        "---\ndescription: ships it\n---\nUpstream.\n",
    )
    .unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n\n[agents.scout]\nsource = \"cat\"\n\n[commands.ship]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    World {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project { root: project },
        home,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn write_at(path: PathBuf, body: &str) -> PathBuf {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, body).unwrap();
    path
}

fn report(w: &World) -> String {
    drift::report::render_plain(&drift::report::check(
        &w.env,
        std::slice::from_ref(&w.scope),
    ))
}

/// Two different problems with two different fixes. Collapsed into one
/// count, a reader who ran `kendex findings` found nothing to review and
/// no reason the install was not happening.
#[test]
#[allow(clippy::unwrap_used)]
fn it_is_told_apart_from_a_safety_hold() {
    let w = world();
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );

    let text = report(&w);
    assert!(text.contains("declared but not installed"), "{text}");
    assert!(
        text.contains("skill 'deploy' is declared and nothing is installed"),
        "{text}"
    );
    assert!(text.contains("fix: kendex apply --plan"), "{text}");
    assert!(
        !text.contains("held back"),
        "nothing here is waiting on a safety review: {text}"
    );
}

/// Every kind whose position is a pure function of kind, harness and name
/// is stat-able, so every one of them is reported. A declared command over
/// pre-existing files was the exact dead end this section exists to close,
/// and it stayed open while only agents and skills were walked.
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_over_existing_files_is_reported_like_any_other_kind() {
    let w = world();
    write_at(
        w.home.join("app/.claude/commands/ship.md"),
        "the tool that came before",
    );

    let text = report(&w);
    assert!(
        text.contains("command 'ship' is declared and nothing is installed"),
        "{text}"
    );
}

/// A link is never taken over — that exit belongs to adopt alone — so a
/// report built from stats must not answer one with the take-over. It says
/// what it saw and sends the reader to the plan, which names what a link
/// actually needs.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_at_the_position_is_never_answered_with_a_take_over() {
    let w = world();
    let elsewhere = w.home.join("somewhere/deploy");
    fs::create_dir_all(&elsewhere).unwrap();
    let position = w.home.join("app/.claude/skills/deploy");
    fs::create_dir_all(position.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &position).unwrap();

    let text = report(&w);
    assert!(text.contains("skill 'deploy' is declared"), "{text}");
    assert!(
        !text.contains("--replace-unmanaged"),
        "the take-over provably refuses a link, so it is never the fix: {text}"
    );
    assert!(text.contains("fix: kendex apply --plan"), "{text}");
}

/// Bytes that already match the declared render block nothing: the apply
/// only writes the record. A report that called that state blocked and
/// prescribed replacing the files would be prescribing a destructive fix
/// for a problem that does not exist.
#[test]
#[allow(clippy::unwrap_used)]
fn bytes_that_already_match_are_never_prescribed_a_replacement() {
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan, None).unwrap();
    // The record gone, the rendered files staying: nothing is installed as
    // far as kendex knows, and everything is already in place.
    fs::remove_file(kendex_core::lock::lock_path(&w.env, &w.scope)).unwrap();

    let text = report(&w);
    assert!(text.contains("declared but not installed"), "{text}");
    assert!(
        !text.contains("replace") && !text.contains("adopt"),
        "no exit is prescribed for a state a stat cannot judge: {text}"
    );

    let re = plan_apply(&w.env, &w.scope, &PlanOptions::default()).unwrap();
    assert!(
        re.drift.iter().all(|row| row.state != DriftState::Conflict),
        "nothing was blocked: {:?}",
        re.drift
    );
    assert!(
        !re.plan
            .ops
            .iter()
            .any(|op| op.description.contains("trash")),
        "and nothing needed replacing: {:?}",
        re.plan.ops
    );
}

/// The refusal offers adoption as one of its two ways out. For a kind
/// `kendex adopt` refuses, naming it would send the reader to a command
/// that errors — the same dead end the message exists to close.
#[test]
#[allow(clippy::unwrap_used)]
fn the_refusal_offers_adoption_only_where_adoption_can_go() {
    let w = world();
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );
    write_at(
        w.home.join("app/.claude/commands/ship.md"),
        "the tool that came before",
    );

    let report = audit(&w.env, &w.scope).unwrap();
    let detail = |name: &str| {
        report
            .drift
            .iter()
            .find(|row| row.name == name && row.state == DriftState::Conflict)
            .map(|row| row.detail.clone())
            .unwrap_or_default()
    };
    assert!(
        detail("deploy").contains("adopt them"),
        "{}",
        detail("deploy")
    );
    assert!(
        !detail("ship").contains("adopt"),
        "adopt refuses a command: {}",
        detail("ship")
    );
    assert!(
        detail("ship").contains("replace them with what you declared"),
        "{}",
        detail("ship")
    );
}
