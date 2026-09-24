//! The pass is paid for once per state: its verdicts are memoized under
//! the inputs they were measured from, a check inside the session hook's
//! budget gives the plan up rather than outrunning the hook, and the
//! background refresh finishes what the budget cut short.

use std::fs;
use std::time::Duration;

use kendex_core::apply;
use kendex_core::drift;
use kendex_core::drift::copies;
use kendex_core::engine::{PlanOptions, audit, plan_apply};

use super::{report, world, write_at};
use crate::test_util::rooted;

/// A second check on the same state reads the memo, never the plan: the
/// verdict is whatever the memo says. The file is edited between the two
/// checks, and the second prints the edit — a check that planned again
/// would print what the plan measured.
#[test]
#[allow(clippy::unwrap_used)]
fn the_same_state_is_judged_once_and_read_after() {
    let w = world();
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );
    let text = report(&w);
    assert!(text.contains(": 1 file differs from"), "{text}");
    let memo = copies::memo_path(&w.env, &w.scope);
    let written = fs::read_to_string(&memo).unwrap();
    assert!(written.contains("\"files\": 1"), "{written}");
    fs::write(&memo, written.replace("\"files\": 1", "\"files\": 7")).unwrap();

    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    let text = drift::report::render_plain(&checked);
    assert!(
        text.contains(": 7 files differ from"),
        "the verdict is read, not measured again: {text}"
    );
    assert!(
        !checked.deep_pass_owed
            && !drift::report::wants_background_refresh(
                &w.env,
                std::slice::from_ref(&w.scope),
                &checked
            ),
        "a state the memo answers for sends nothing to the background"
    );

    // The copy moves: the memo no longer answers for it, and the next
    // check measures again.
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before, edited",
    );
    let text = report(&w);
    assert!(text.contains(": 1 file differs from"), "{text}");
}

/// A plan the budget cuts short is a line the check could not produce,
/// naming the budget, with every copy left as the stat found it — never a
/// hook the harness kills with the whole report inside it. The report
/// says the pass is owed, which is what sends the caller's background
/// refresh through it; that job's pass writes the memo the next check
/// reads.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pass_past_the_budget_is_given_up_and_finished_in_the_background() {
    let w = world();
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );
    let checked =
        drift::report::check_within(&w.env, std::slice::from_ref(&w.scope), Duration::ZERO);
    let text = drift::report::render_plain(&checked);
    assert_eq!(
        checked.status,
        drift::report::CheckStatus::Unknown,
        "{text}"
    );
    assert!(
        text.contains(
            "could not be compared with their source inside the 0 s the session hook allows"
        ),
        "{text}"
    );
    assert!(
        !text.contains("background"),
        "the line promises nothing about a refresh the caller may have switched off: {text}"
    );
    assert!(
        text.contains("kendex.toml asks for skill 'deploy' for Claude Code")
            && !text.contains("--replace-unmanaged"),
        "nothing judged prescribes no exit: {text}"
    );
    assert!(
        checked.deep_pass_owed
            && drift::report::wants_background_refresh(
                &w.env,
                std::slice::from_ref(&w.scope),
                &checked
            ),
        "a pass given up is reported as owed, which is what sends the caller's refresh through it"
    );

    copies::derive(&w.env, &w.scope).unwrap();
    assert!(copies::memo_path(&w.env, &w.scope).is_file());
    let text = report(&w);
    assert!(
        text.contains("unmanaged copy of skill 'deploy' for Claude Code: 1 file differs from"),
        "the next check reads what the background pass measured: {text}"
    );
}

/// A record that cannot be written leaves every copy it would have
/// recorded where the stat found it — blocked, with the plan to see — and
/// the reason under `could not check`, so the report says it is
/// incomplete rather than clean.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_that_will_not_write_is_could_not_check() {
    use std::os::unix::fs::PermissionsExt;
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    fs::remove_file(&lock_path).unwrap();
    let project = w.home.join("app");
    fs::set_permissions(&project, fs::Permissions::from_mode(0o500)).unwrap();
    let restore = || fs::set_permissions(&project, fs::Permissions::from_mode(0o755)).unwrap();

    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    let text = drift::report::render_plain(&checked);
    restore();
    assert_eq!(
        checked.status,
        drift::report::CheckStatus::Unknown,
        "{text}"
    );
    assert!(
        text.contains("files matching their source could not be recorded as installed: "),
        "{text}"
    );
    assert!(
        text.contains("kendex.toml asks for skill 'deploy' for Claude Code")
            && text.contains("see: kendex apply --plan"),
        "an unrecorded copy stands as the stat found it: {text}"
    );
    assert!(!lock_path.exists(), "nothing was recorded");
    assert_eq!(
        report(&w),
        "",
        "with the directory writable again the next check records it"
    );
    assert!(lock_path.is_file());
}

/// A record write retires the memo, whoever made it: what a plan proved it
/// proved against the record as it stood, and a proven entry a stat never
/// keyed — a hook's script — would otherwise be written over whatever a
/// later apply recorded for it. The memo is left holding proven entries
/// by a record write that failed; an apply then records them all and the
/// person edits one; the next check, still occupied by a differing copy,
/// keeps that edit.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_write_retires_the_memo() {
    use std::os::unix::fs::PermissionsExt;
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    fs::remove_file(&lock_path).unwrap();
    write_at(
        w.home.join("app/.claude/commands/ship.md"),
        "the tool that came before",
    );
    let project = w.home.join("app");
    fs::set_permissions(&project, fs::Permissions::from_mode(0o500)).unwrap();
    let text = report(&w);
    fs::set_permissions(&project, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(
        text.contains("could not be recorded as installed"),
        "{text}"
    );
    let memo = fs::read_to_string(copies::memo_path(&w.env, &w.scope)).unwrap();
    assert!(
        memo.contains("hook:guard:claude"),
        "the memo holds what it proved: {memo}"
    );

    let planned = plan_apply(&w.env, &w.scope, &PlanOptions::default()).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let mut recorded = kendex_core::lock::load(&lock_path).unwrap();
    let guard = kendex_core::lock::entry_key(
        kendex_core::model::ItemKind::Hook,
        "guard",
        kendex_core::model::HarnessId::Claude,
    );
    recorded.entries.get_mut(&guard).unwrap().upstream_skills = Some(vec!["edited".to_owned()]);
    kendex_core::lock::save(&lock_path, &recorded).unwrap();

    let text = report(&w);
    assert!(text.contains("unmanaged copy of command 'ship'"), "{text}");
    let after = kendex_core::lock::load(&lock_path).unwrap();
    assert_eq!(
        after.entries[&guard].upstream_skills.as_deref(),
        Some(["edited".to_owned()].as_slice()),
        "an entry the apply recorded is not written over by what an earlier plan proved"
    );
}

/// A proven copy whose file vanished between the plan and the record is
/// refused, never recorded. The memo carries the proven set across
/// sessions and keys only the occupied installations, so the agent's file
/// is deleted after the background pass memoized it while a differing
/// command keeps the memo answering; the check that reads the memo refuses
/// the record, and the check after, planning afresh, records what still
/// proves itself and not the entry whose file is gone. Recorded, the empty
/// position would be kendex's own, and the tool writing its file back
/// there would be written over without a word.
#[test]
#[allow(clippy::unwrap_used)]
fn a_proven_copy_that_vanished_is_refused_by_the_binding() {
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    fs::remove_file(&lock_path).unwrap();
    write_at(
        w.home.join("app/.claude/commands/ship.md"),
        "the tool that came before",
    );
    copies::derive(&w.env, &w.scope).unwrap();
    let scout = kendex_core::lock::entry_key(
        kendex_core::model::ItemKind::Agent,
        "scout",
        kendex_core::model::HarnessId::Claude,
    );
    let memo = fs::read_to_string(copies::memo_path(&w.env, &w.scope)).unwrap();
    assert!(
        memo.contains(&scout),
        "the fixture is not the state it is testing: {memo}"
    );
    fs::remove_file(w.home.join("app/.claude/agents/scout.md")).unwrap();

    let text = report(&w);
    assert!(
        text.contains("could not be recorded as installed"),
        "{text}"
    );
    assert!(
        kendex_core::lock::load(&lock_path)
            .ok()
            .is_none_or(|recorded| !recorded.entries.contains_key(&scout)),
        "a file gone since the plan was recorded as installed"
    );

    let text = report(&w);
    let recorded = kendex_core::lock::load(&lock_path).unwrap();
    assert!(
        recorded.entries.contains_key("skill:deploy:claude")
            && !recorded.entries.contains_key(&scout),
        "the next check records what still proves itself and nothing else: {text}\n{:?}",
        recorded.entries.keys()
    );
}

/// A proven registration whose settings file moved between the plan and
/// the record is refused, never recorded, whether the registration was
/// taken out or the file was left in a shape the edit cannot read. No
/// settings file is keyed, so the file is rewritten after the background
/// pass memoized the hook as proven while a differing command keeps the
/// memo answering; the check that reads the memo refuses the record
/// naming the reason, and the check after, planning afresh, records what
/// still proves itself and not the hook. Recorded, the next apply would
/// put the registration the person took out straight back.
#[test]
#[allow(clippy::unwrap_used)]
fn a_proven_registration_taken_out_is_refused_by_the_binding() {
    // What the settings file holds after the plan, and the reason the
    // refusal names for it.
    let rows: [(&str, &str); 2] = [
        ("{}\n", "plan is stale"),
        ("{\"hooks\": \n", "structured edit failed"),
    ];
    for (settings_after, reason) in rows {
        let w = world();
        let planned = audit(&w.env, &w.scope).unwrap();
        apply::execute(&w.env, &planned.plan).unwrap();
        let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
        fs::remove_file(&lock_path).unwrap();
        write_at(
            w.home.join("app/.claude/commands/ship.md"),
            "the tool that came before",
        );
        copies::derive(&w.env, &w.scope).unwrap();
        let guard = kendex_core::lock::entry_key(
            kendex_core::model::ItemKind::Hook,
            "guard",
            kendex_core::model::HarnessId::Claude,
        );
        let memo = fs::read_to_string(copies::memo_path(&w.env, &w.scope)).unwrap();
        assert!(
            memo.contains(&guard),
            "the fixture is not the state it is testing: {memo}"
        );
        let settings = w.home.join("app/.claude/settings.json");
        assert!(
            fs::read_to_string(&settings).unwrap().contains("guard.sh"),
            "the fixture is not the state it is testing: the hook is not registered"
        );
        fs::write(&settings, settings_after).unwrap();

        let text = report(&w);
        assert!(
            text.contains("could not be recorded as installed") && text.contains(reason),
            "{settings_after:?}: the refusal names its reason: {text}"
        );
        assert!(
            kendex_core::lock::load(&lock_path)
                .ok()
                .is_none_or(|recorded| !recorded.entries.contains_key(&guard)),
            "{settings_after:?}: a registration gone since the plan was recorded as installed"
        );

        let text = report(&w);
        let recorded = kendex_core::lock::load(&lock_path).unwrap();
        assert!(
            recorded.entries.contains_key("skill:deploy:claude")
                && !recorded.entries.contains_key(&guard),
            "{settings_after:?}: the next check records what still proves itself and nothing else: {text}\n{:?}",
            recorded.entries.keys()
        );
        assert_eq!(
            fs::read_to_string(&settings).unwrap(),
            settings_after,
            "the check registers nothing"
        );
    }
}

/// A proven registration whose settings file the harness has since
/// stopped reading is refused, never recorded. OpenCode reads a global
/// `opencode.jsonc` as soon as one appears beside `opencode.json`, and no
/// settings file is keyed, so a differing command keeps the memo
/// answering after the person creates one; the check that reads the memo
/// refuses the record naming the file the plan never held, and the check
/// after, planning afresh, records what still proves itself and not the
/// server. Recorded, the next apply would write the server into the new
/// file as if it had always been there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_proven_registration_whose_target_moved_is_refused_by_the_binding() {
    let w = global_world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    fs::remove_file(&lock_path).unwrap();
    write_at(
        w.home.join(".claude/commands/ship.md"),
        "the tool that came before",
    );
    copies::derive(&w.env, &w.scope).unwrap();
    let gh = kendex_core::lock::entry_key(
        kendex_core::model::ItemKind::McpServer,
        "gh",
        kendex_core::model::HarnessId::Opencode,
    );
    let memo = fs::read_to_string(copies::memo_path(&w.env, &w.scope)).unwrap();
    assert!(
        memo.contains(&gh),
        "the fixture is not the state it is testing: {memo}"
    );
    let json = w.home.join(".config/opencode/opencode.json");
    assert!(
        fs::read_to_string(&json).unwrap().contains("\"gh\""),
        "the fixture is not the state it is testing: the server is not registered"
    );
    let jsonc = write_at(w.home.join(".config/opencode/opencode.jsonc"), "{}\n");

    let text = report(&w);
    assert!(
        text.contains("could not be recorded as installed")
            && text.contains("plan is stale")
            && text.contains("opencode.jsonc"),
        "the refusal names the file the harness reads now: {text}"
    );
    assert!(
        kendex_core::lock::load(&lock_path)
            .ok()
            .is_none_or(|recorded| !recorded.entries.contains_key(&gh)),
        "a registration in a file the harness stopped reading was recorded as installed"
    );

    let text = report(&w);
    let recorded = kendex_core::lock::load(&lock_path).unwrap();
    assert!(
        recorded.entries.contains_key("skill:deploy:claude") && !recorded.entries.contains_key(&gh),
        "the next check records what still proves itself and nothing else: {text}\n{:?}",
        recorded.entries.keys()
    );
    assert_eq!(
        fs::read_to_string(&jsonc).unwrap(),
        "{}\n",
        "the check registers nothing"
    );
}

/// The `world` catalog plus an MCP server, declared for the person's own
/// scope where OpenCode picks its config file by what exists.
#[allow(clippy::unwrap_used)]
fn global_world() -> super::World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    write_at(catalog.join("kendex.toml"), "is_source_catalog = true\n");
    write_at(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    );
    write_at(
        catalog.join("commands/ship.md"),
        "---\ndescription: ships it\n---\nUpstream.\n",
    );
    write_at(
        catalog.join("mcp/gh.toml"),
        "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n",
    );
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(home.join(".config/opencode")).unwrap();
    let env = kendex_core::env::Env::fake(&home, kendex_core::env::FakeOs::Linux);
    let scope = kendex_core::model::Scope::Global;
    write_at(
        kendex_core::manifest::manifest_path(&env, &scope),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n\n[commands.ship]\nsource = \"cat\"\n\n[mcp-servers.gh]\nsource = \"cat\"\n",
            super::source_path(&catalog)
        ),
    );
    super::World {
        env,
        scope,
        home,
        _tmp: tmp,
    }
}

/// A proven copy the record gained is planned again, never read from the
/// memo the write left behind: that memo is kept under the pre-write keys
/// and holds nothing left to record, so a lock removed after a silent
/// claim — a checkout to the branch that lacks it — would hit it and
/// report every recorded copy blocked at every check, where a plan proves
/// and records them again. The differing copy's verdict stays memoized
/// across the write.
#[test]
#[allow(clippy::unwrap_used)]
fn a_lock_removed_after_a_silent_claim_is_recorded_again() {
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    fs::remove_file(&lock_path).unwrap();
    write_at(
        w.home.join("app/.claude/skills/deploy/SKILL.md"),
        "the tool that came before",
    );
    let guard = kendex_core::lock::entry_key(
        kendex_core::model::ItemKind::Hook,
        "guard",
        kendex_core::model::HarnessId::Claude,
    );
    let text = report(&w);
    assert!(text.contains(": 1 file differs from"), "{text}");
    assert!(
        kendex_core::lock::load(&lock_path)
            .unwrap()
            .entries
            .contains_key(&guard),
        "the first check records the proven copies"
    );

    fs::remove_file(&lock_path).unwrap();
    let text = report(&w);
    assert!(text.contains(": 1 file differs from"), "{text}");
    assert!(
        kendex_core::lock::load(&lock_path)
            .unwrap()
            .entries
            .contains_key(&guard),
        "a lock removed after the claim is proved and recorded again, never read as blocked: {text}"
    );
}
