//! What the session check does about a declaration whose files are already
//! on disk. The check reads the manifest, the lock and a stat to find the
//! state, then plans the scope once to judge it: a copy the render matches
//! is recorded without a word, a copy that differs is stale with the count
//! and the take-over as its fix, and a position the plan cannot read as
//! content keeps the line a stat can stand behind, with the plan as what
//! to see next.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;
use test_util::source_path;

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
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = {harnesses}\nmethod = \"{method}\"\n\n{body}",
            source_path(&w.home.join("catalog"))
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

/// A copy that is not the render is stale — the section an agent reads
/// first, since this state is most often a render some commits behind —
/// with how many files differ, what they were measured against, and the
/// take-over as the fix. Nothing about it reads as a safety question, and
/// nothing sends the reader to a plan for a state the plan already judged.
/// The fix it names settles it, and a copy that differs is never recorded.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_that_differs_is_stale_and_the_take_over_is_its_fix() {
    let w = world();
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );

    let text = report(&w);
    assert!(text.starts_with("stale:\n"), "{text}");
    assert!(
        text.contains(
            "unmanaged copy of skill 'deploy' for Claude Code: 1 file differs from source 'cat' — fix: kendex apply --replace-unmanaged"
        ),
        "{text}"
    );
    assert!(
        !text.contains("blocked by files already there") && !text.contains("--plan"),
        "the plan judged it, so no line sends the reader to the plan: {text}"
    );
    assert!(
        !text.contains("held back"),
        "nothing here reads as a safety hold: {text}"
    );
    assert!(
        !kendex_core::lock::lock_path(&w.env, &w.scope).exists(),
        "a copy that differs is never recorded as installed"
    );

    let taken = plan_apply(
        &w.env,
        &w.scope,
        &PlanOptions {
            replace_unmanaged: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &taken.plan).unwrap();
    assert_eq!(report(&w), "", "the fix the line named settles it");
}

/// Every kind whose position is a pure function of kind, harness and name
/// is stat-able, so every one of them is judged. A declared command over
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
        text.contains("unmanaged copy of command 'ship' for Claude Code: 1 file differs from"),
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

/// Bytes that already match the declared render block nothing: either
/// exit lands the same bytes, so the check writes the record and says
/// nothing — the state a clone carrying committed renders and no record
/// starts in, and the state an earlier build left every project in. The
/// record it writes says what the apply's said, entry for entry, and the
/// files stay as they were; a second look has nothing to write.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_the_render_matches_is_recorded_without_a_word() {
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let applied = kendex_core::lock::load(&lock_path).unwrap();
    let rendered = w.home.join("app/.claude/skills/deploy/SKILL.md");
    let before = fs::read(&rendered).unwrap();
    // The record gone, the rendered files staying: nothing is installed as
    // far as kendex knows, and everything is already in place.
    fs::remove_file(&lock_path).unwrap();

    assert_eq!(report(&w), "", "nothing to decide, so nothing said");
    let claimed = kendex_core::lock::load(&lock_path).unwrap();
    assert_eq!(
        claimed.entries.keys().collect::<Vec<_>>(),
        applied.entries.keys().collect::<Vec<_>>(),
        "every declared install is recorded"
    );
    for (key, entry) in &applied.entries {
        let recorded = &claimed.entries[key];
        assert_eq!(recorded.source_hash, entry.source_hash, "{key}");
        assert_eq!(recorded.rendered_hash, entry.rendered_hash, "{key}");
        assert_eq!(recorded.emitted, entry.emitted, "{key}");
    }
    assert_eq!(
        fs::read(&rendered).unwrap(),
        before,
        "the files stay as they were"
    );

    let written = fs::read(&lock_path).unwrap();
    assert_eq!(report(&w), "");
    assert_eq!(
        fs::read(&lock_path).unwrap(),
        written,
        "a record that already holds every install is not rewritten"
    );
    let re = plan_apply(&w.env, &w.scope, &PlanOptions::default()).unwrap();
    assert!(
        re.drift.iter().all(|row| row.state != DriftState::Conflict),
        "nothing was blocked: {:?}",
        re.drift
    );
}

/// A record that already holds other installs keeps them and gains the
/// one that proved itself: the check adds entries, never rebuilds the
/// record, so what an earlier apply recorded about its neighbours is not
/// re-derived by a pass that did not write them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_matching_copy_joins_a_record_that_already_holds_others() {
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let applied = kendex_core::lock::load(&lock_path).unwrap();
    let scout = kendex_core::lock::entry_key(
        kendex_core::model::ItemKind::Agent,
        "scout",
        kendex_core::model::HarnessId::Claude,
    );
    let mut partial = applied.clone();
    partial.entries.remove(&scout).unwrap();
    kendex_core::lock::save(&lock_path, &partial).unwrap();

    assert_eq!(report(&w), "");
    let claimed = kendex_core::lock::load(&lock_path).unwrap();
    assert!(
        claimed.entries.contains_key(&scout),
        "{:?}",
        claimed.entries.keys()
    );
    for (key, entry) in &partial.entries {
        assert_eq!(
            &claimed.entries[key], entry,
            "{key}: an entry the record held is kept as it was"
        );
    }
}

/// Each copy is judged on its own: the ones that match are recorded, the
/// one that differs is reported, in one pass. Half a record is a record
/// of what proved itself, never a refusal of the whole scope.
#[test]
#[allow(clippy::unwrap_used)]
fn each_copy_is_settled_on_its_own() {
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    fs::remove_file(&lock_path).unwrap();
    write_at(
        w.home.join("app/.claude/commands/ship.md"),
        "the tool that came before",
    );

    let text = report(&w);
    assert!(
        text.contains("unmanaged copy of command 'ship' for Claude Code: 1 file differs from"),
        "{text}"
    );
    assert!(
        !text.contains("'deploy'") && !text.contains("'scout'") && !text.contains("'guard'"),
        "the copies that match are not a line: {text}"
    );
    let claimed = kendex_core::lock::load(&lock_path).unwrap();
    let recorded: Vec<&str> = claimed
        .entries
        .values()
        .map(|entry| entry.name.as_str())
        .collect();
    assert_eq!(recorded, ["scout", "guard", "deploy"], "{recorded:?}");
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
    apply::execute(&w.env, &planned.plan).unwrap();
    assert_eq!(report(&w), "", "what was asked for is installed");

    // Another tool joins the list while the first tool still holds its place.
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
        text.contains("unmanaged copy of skill 'deploy' for OpenCode: 1 file differs from"),
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
