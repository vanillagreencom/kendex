//! What the check may claim for each kind, given that all it reads is the
//! manifest, the lock and a stat.

use kendex_core::apply;
use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};

use super::{declare, report, world, write_at};

/// Codex takes a command as a one-file skill tree, so that tree is where
/// its copy actually lands — not the command directory the name suggests.
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_is_read_at_the_position_its_tool_installs_it_to() {
    let w = world();
    declare(
        &w,
        "copy",
        "[\"codex\"]",
        "[commands.ship]\nsource = \"cat\"\n",
    );
    write_at(
        w.home.join("app/.agents/skills/ship/SKILL.md"),
        "the tool that came before",
    );

    let text = report(&w);
    assert!(
        text.contains("kendex.toml asks for command 'ship'"),
        "{text}"
    );
}

/// One item, two tools, one of them installed. The line is about the tool
/// that is blocked — said only by name it claimed nothing was installed,
/// which the tool with its copy makes false, in a report an agent reads as
/// the project's state.
#[test]
#[allow(clippy::unwrap_used)]
fn the_line_names_the_tool_it_is_about() {
    let w = world();
    declare(
        &w,
        "copy",
        "[\"claude\"]",
        "[skills.deploy]\nsource = \"cat\"\n",
    );
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
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
        text.contains("skill 'deploy' for OpenCode"),
        "the blocked tool is named: {text}"
    );
    assert!(
        !text.contains("for Claude Code"),
        "and the one that has it is not: {text}"
    );
}

/// The check and the plan have to name the same problem. Skipping an item
/// because the lock holds a key for it is the ownership error this section
/// exists to close, one surface further along: a skill that moves from a
/// copy per tool to one shared tree installs somewhere the old install
/// never wrote, and whatever already lives there is a stranger's. The plan
/// says so; the check said the session was clean, so nothing pointed at
/// the plan that would have said it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_that_changed_how_it_installs_is_reported_by_the_check_too() {
    let w = world();
    let first = plan_apply(&w.env, &w.scope, &PlanOptions::default()).unwrap();
    apply::execute(&w.env, &first.plan).unwrap();

    declare(
        &w,
        "symlink",
        "[\"claude\"]",
        "[skills.deploy]\nsource = \"cat\"\n",
    );
    write_at(
        w.home.join("app/.agents/skills/deploy/SKILL.md"),
        "the tool that came before",
    );

    let planned = plan_apply(&w.env, &w.scope, &PlanOptions::default()).unwrap();
    assert!(
        planned.drift.iter().any(
            |row| row.name == "deploy" && row.state == DriftState::Unmanaged
                || row.cause.is_some_and(|cause| cause.in_the_way())
        ),
        "the fixture is not the state it is testing: {:?}",
        planned.drift
    );

    let text = report(&w);
    assert!(
        text.contains("blocked by files already there"),
        "the check called the session clean while the plan was blocked: {text}"
    );
}
