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
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::write(
        catalog.join("hooks/guard.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: watches shell commands\n# ---\nexit 0\n",
    )
    .unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let w = World {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        home,
        _tmp: tmp,
    };
    declare(
        &w,
        "copy",
        "[\"claude\"]",
        "[skills.deploy]\nsource = \"cat\"\n\n[agents.scout]\nsource = \"cat\"\n\n[commands.ship]\nsource = \"cat\"\n\n[hooks.guard]\nsource = \"cat\"\n",
    );
    w
}

/// Point the project at a set of tools, an install method, and a body of
/// declarations.
#[allow(clippy::unwrap_used)]
fn declare(w: &World, method: &str, harnesses: &str, body: &str) {
    fs::write(
        w.home.join("app/kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = {harnesses}\nmethod = \"{method}\"\n\n{body}",
            w.home.join("catalog").display()
        ),
    )
    .unwrap();
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
    assert!(text.contains("blocked by files already there"), "{text}");
    assert!(
        text.contains("kendex.toml asks for skill 'deploy' for Claude Code, and files are"),
        "{text}"
    );
    assert!(
        text.contains("see: kendex apply --plan"),
        "a read-only next step is not a fix: {text}"
    );
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
        text.contains("kendex.toml asks for command 'ship' for Claude Code, and files are"),
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
    assert!(
        text.contains("kendex.toml asks for skill 'deploy'"),
        "{text}"
    );
    assert!(
        !text.contains("--replace-unmanaged"),
        "the take-over provably refuses a link, so it is never the fix: {text}"
    );
    assert!(
        text.contains("see: kendex apply --plan"),
        "a read-only next step is not a fix: {text}"
    );
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
    assert!(text.contains("blocked by files already there"), "{text}");
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

/// Read per installation, not per declaration. One tool having its copy
/// says nothing about the tool that does not — and the shared tree the
/// first one wrote is kendex's own, never a stranger's.
#[test]
#[allow(clippy::unwrap_used)]
fn a_tool_without_its_copy_is_read_on_its_own() {
    let w = world();
    declare(
        &w,
        "copy",
        "[\"claude\"]",
        "[skills.deploy]\nsource = \"cat\"\n",
    );
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan, None).unwrap();
    assert_eq!(report(&w), "", "what was asked for is installed");

    // A second tool added to the list later, with the tool that came before
    // still holding its place.
    declare(
        &w,
        "copy",
        "[\"claude\", \"opencode\"]",
        "[skills.deploy]\nsource = \"cat\"\n",
    );
    write_at(
        w.home.join("app/.opencode/skills/deploy/SKILL.md"),
        "the tool that came before",
    );

    let text = report(&w);
    assert!(
        text.contains("kendex.toml asks for skill 'deploy'"),
        "one tool having its copy says nothing about the tool that does not: {text}"
    );
}

/// Copy keeps every tool's own directory. Unrelated content under the
/// shared tree is not in that install's way, and reporting it would send a
/// reader to decide about files their declaration will never touch.
#[test]
#[allow(clippy::unwrap_used)]
fn the_shared_tree_is_not_in_a_copied_installs_way() {
    let w = world();
    write_at(
        w.home.join("app/.agents/skills/deploy/SKILL.md"),
        "someone else's tree",
    );

    let text = report(&w);
    assert!(!text.contains("'deploy'"), "{text}");
}

/// Whether a hook writes a file at all is in its source, which this check
/// does not read: a hook whose body is a command registers that command
/// and writes nothing. Claiming the script path it would otherwise have
/// tells the reader they are blocked and sends them to a plan with no
/// conflict to show them — so the check says nothing about hooks, and the
/// plan, which reads the source, says it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_is_left_to_the_plan_that_can_read_it() {
    let w = world();
    write_at(
        w.home.join("app/.claude/hooks/guard.sh"),
        "#!/usr/bin/env bash\n# the tool that came before\n",
    );

    let text = report(&w);
    assert!(!text.contains("'guard'"), "{text}");

    let planned = plan_apply(&w.env, &w.scope, &PlanOptions::default()).unwrap();
    assert!(
        planned
            .drift
            .iter()
            .any(|row| row.name == "guard" && row.state == DriftState::Conflict),
        "the plan that can read the source has to say it: {:?}",
        planned.drift
    );
}

mod kinds;
