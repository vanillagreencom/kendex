//! When the stale line may name the take-over. The scope-wide sweep
//! settles every position it sweeps up or none of them, so the line
//! names it only where the pass answered for the whole scope: the sweep
//! would not refuse, every position it would take was measured, and no
//! row's take-over moves a position the line never named. Otherwise the
//! plan, which names every position, is what to see next.

use std::fs;
use std::path::Path;

use super::{World, declare, report, world, write_at};

/// A folder of the person's own files where a skill goes.
#[allow(clippy::unwrap_used)]
fn folder_at(path: &Path) {
    write_at(
        path.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nBy hand.\n",
    );
}

#[allow(clippy::unwrap_used)]
fn link_at(path: &Path, target: &Path) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(target, path).unwrap();
}

/// One row per shape the sweep cannot answer for, each asserting the
/// differing copy's line sends the reader to the plan and nothing in the
/// report names the take-over. The control is the first row's shape with
/// the second tool's link removed, which is the scope the sweep settles.
#[test]
#[allow(clippy::unwrap_used)]
fn the_take_over_is_named_only_where_the_sweep_settles_the_scope() {
    type Plant = fn(&World);
    let rows: [(&str, &str, Plant, &str); 3] = [
        (
            "a differing copy at one tool and a shared folder linked at another, one item",
            "copy",
            |w| {
                folder_at(&w.home.join("app/.claude/skills/deploy"));
                let shared = w.home.join("shared/deploy");
                folder_at(&shared);
                link_at(&w.home.join("app/.agents/skills/deploy"), &shared);
            },
            "unmanaged copy of skill 'deploy' for Claude Code: 1 file differs from source 'cat' — see: kendex apply --plan",
        ),
        (
            "a differing copy beside a file where another item's tree goes",
            "copy",
            |w| {
                write_at(
                    w.home.join("app/.claude/commands/ship.md"),
                    "the tool that came before",
                );
                write_at(
                    w.home.join("app/.claude/skills/deploy"),
                    "a file, not a tree",
                );
            },
            "unmanaged copy of command 'ship' for Claude Code: 1 file differs from source 'cat' — see: kendex apply --plan",
        ),
        (
            "the person's own folders at both the shared tree and the tool's own position",
            "symlink",
            |w| {
                folder_at(&w.home.join("app/.agents/skills/deploy"));
                folder_at(&w.home.join("app/.claude/skills/deploy"));
            },
            "unmanaged copy of skill 'deploy' for Claude Code: 1 file differs from source 'cat' — see: kendex apply --plan",
        ),
    ];
    for (what, method, plant, line) in rows {
        let w = world();
        declare(
            &w,
            method,
            "[\"claude\", \"codex\"]",
            "[skills.deploy]\nsource = \"cat\"\n\n[commands.ship]\nsource = \"cat\"\n",
        );
        plant(&w);
        let text = report(&w);
        assert!(text.contains(line), "{what}: {text}");
        assert!(
            !text.contains("--replace-unmanaged"),
            "{what}: a take-over that settles only part of the scope is never named: {text}"
        );
    }

    let w = world();
    declare(
        &w,
        "copy",
        "[\"claude\"]",
        "[skills.deploy]\nsource = \"cat\"\n\n[commands.ship]\nsource = \"cat\"\n",
    );
    folder_at(&w.home.join("app/.claude/skills/deploy"));
    let text = report(&w);
    assert!(
        text.contains(
            "unmanaged copy of skill 'deploy' for Claude Code: 1 file differs from source 'cat'"
        ),
        "the control: a scope the sweep settles names it: {text}"
    );
    assert!(
        text.contains("fix: kendex apply --replace-unmanaged"),
        "the control: a scope the sweep settles names it: {text}"
    );
}
