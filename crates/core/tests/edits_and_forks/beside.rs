//! Installing beside: the edited copy becomes the user's own package under
//! a new name and the source's version comes back under the old one — with
//! everything proven before anything is written.

use std::fs;

use kendex_core::error::CoreError;

use super::*;

/// Installing beside: the edits become the user's own package under the
/// new name, answering to it, and the original name goes back to its
/// source — the newest version when the hold moves along.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_keeps_the_edit_under_a_new_name_and_lands_the_source_under_the_old() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    let one = head_commit(&w.upstream);
    declare(
        &w,
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{one}\"\n"),
    );
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMy fork.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "gh", "Upstream v2.");
    commit(&w.upstream, "two");
    let two = head_commit(&w.upstream);
    // The edit holds the place through a refresh; the mirror still learns
    // about the newer commit.
    sync_and_apply(&w);
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("My fork.")
    );

    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-edited",
        Some(&two),
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    // The fork's bytes live in the local source under the new name and say
    // that name; they render there too.
    let own =
        fs::read_to_string(w.home.join("app/.kendex-local/skills/gh-edited/SKILL.md")).unwrap();
    assert!(
        own.contains("My fork.") && own.contains("name: gh-edited"),
        "{own}"
    );
    assert!(
        fs::read_to_string(w.home.join("app/.agents/skills/gh-edited/SKILL.md"))
            .unwrap()
            .contains("My fork.")
    );
    // The original name carries the source's newest version, held there.
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("Upstream v2.")
    );
    let text = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert!(
        text.contains("[skills.gh-edited]\nsource = \"local\""),
        "{text}"
    );
    assert!(text.contains("[forks.skill.gh-edited]"), "{text}");
    assert!(
        text.contains(&format!("[skills.gh]\nsource = \"cat\"\nrev = \"{two}\"")),
        "{text}"
    );
    assert!(audit(&w.env, &w.scope).unwrap().drift.is_empty());

    let rows = kendex_core::package::updates::updates(&w.env, &w.scope)
        .unwrap()
        .rows;
    let gh = rows.iter().find(|row| row.name == "gh").unwrap();
    assert!(!gh.blocked_by_local_edit && !gh.update_available, "{gh:?}");
    let own = rows.iter().find(|row| row.name == "gh-edited").unwrap();
    assert!(own.forked && !own.update_available, "{own:?}");
}

/// Everything is proven before anything is written: a refused install
/// beside leaves the manifest byte-identical and the local source empty.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_before_writing_when_the_target_cannot_be_proven() {
    let (w, _one, _two) = edited_world();
    // A commit the item is absent at: the repository's history starts
    // before gh existed.
    write_skill(&w.upstream, "docs", "Docs.");
    commit(&w.upstream, "three");
    let before = manifest_text(&w);
    let beside = |rev: Option<&str>| {
        fork::fork_beside(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "gh",
            HarnessId::Claude,
            "gh-edited",
            rev,
        )
    };

    // An orphan commit in another repository is unknown to this one.
    let absent = beside(Some("0000000000000000000000000000000000000000")).unwrap_err();
    assert!(
        !matches!(absent, CoreError::SourceCollision { .. }),
        "{absent:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(!w.home.join("app/.kendex-local/skills/gh-edited").exists());

    // A branch name resolves to the full commit the manifest records.
    let plan = beside(Some("main")).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let three = head_commit(&w.upstream);
    let text = manifest_text(&w);
    assert!(
        text.contains(&format!("[skills.gh]\nsource = \"cat\"\nrev = \"{three}\"")),
        "{text}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_an_original_its_source_no_longer_carries() {
    // A following original: the tree an apply reads is the source's tip.
    // (A held one keeps reading its held commit, where the item still is.)
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMy fork.\n",
    )
    .unwrap();
    fs::remove_dir_all(w.upstream.join("skills/gh")).unwrap();
    write_skill(&w.upstream, "docs", "Docs.");
    commit(&w.upstream, "gone");
    sync_and_apply(&w);
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-edited",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ItemNotInSource { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(!w.home.join("app/.kendex-local/skills/gh-edited").exists());
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("My fork.")
    );
}

/// A commit the item is absent at is refused by the same rule the hold
/// path enforces: the repository holds the commit, the item is not in it.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_commit_the_item_is_absent_at() {
    let w = world();
    write_skill(&w.upstream, "docs", "Docs.");
    commit(&w.upstream, "zero");
    let zero = head_commit(&w.upstream);
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(skill_file(&w), "---\nname: gh\n---\nMine.\n").unwrap();
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-edited",
        Some(&zero),
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ItemMissingAtRev { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(!w.home.join("app/.kendex-local/skills/gh-edited").exists());
}

/// `rev = None` leaves a hold where it is; the fork record carries the
/// commit the edits were made on.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_without_a_rev_keeps_the_hold_and_records_the_commit() {
    let (w, one, _two) = edited_world();
    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-edited",
        None,
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let text = manifest_text(&w);
    assert!(
        text.contains(&format!("[skills.gh]\nsource = \"cat\"\nrev = \"{one}\"")),
        "{text}"
    );
    let record = text.split("[forks.skill.gh-edited]").nth(1).unwrap();
    assert!(
        record.contains(&format!("commit = \"{one}\"")),
        "the fork record names the commit the edits were made on: {record}"
    );
    assert!(record.contains("source = \"cat\""), "{record}");
    // Held at one, the original renders one's content again.
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("Upstream.")
    );
}

/// An agent forks beside the same way: the local copy answers to the new
/// name, and the tool's file for the old name carries the source again.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_keeps_an_edited_agent_under_the_new_name() {
    let w = world();
    write_agent(&w.upstream, "rev", "Agent body.");
    commit(&w.upstream, "one");
    declare(&w, "[agents.rev]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    let rendered = w.home.join("app/.claude/agents/rev.md");
    assert!(rendered.is_file());
    fs::write(
        &rendered,
        "---\nname: rev\ndescription: mine\n---\nMy agent.\n",
    )
    .unwrap();

    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "rev",
        HarnessId::Claude,
        "rev-edited",
        None,
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let own = fs::read_to_string(w.home.join("app/.kendex-local/agents/rev-edited.md")).unwrap();
    assert!(
        own.contains("name: rev-edited") && own.contains("My agent."),
        "{own}"
    );
    let original = fs::read_to_string(&rendered).unwrap();
    assert!(
        original.contains("Agent body.") && !original.contains("My agent."),
        "{original}"
    );
    let beside = fs::read_to_string(w.home.join("app/.claude/agents/rev-edited.md")).unwrap();
    assert!(
        beside.contains("name: rev-edited") && beside.contains("My agent."),
        "{beside}"
    );
    assert!(manifest_text(&w).contains("[forks.agent.rev-edited]"));
}

/// The fork record names the commit the captured harness's own bytes came
/// from — installations can sit at different commits mid-refresh, and the
/// edits live in the one rendering being kept.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_records_the_captured_harness_own_commit() {
    let (w, one, _two) = edited_world();
    // A second tool's record at another commit, keyed to iterate first: the
    // harness lookup must decide, not iteration order.
    let path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let mut lock = kendex_core::lock::load(&path).unwrap();
    let claude = lock
        .entries
        .values()
        .find(|entry| entry.kind == ItemKind::Skill && entry.name == "gh")
        .unwrap()
        .clone();
    let mut other = claude;
    other.harness = HarnessId::Opencode;
    other.source_commit = Some("0".repeat(40));
    lock.entries.insert("0-opencode-first".to_owned(), other);
    kendex_core::lock::save(&path, &lock).unwrap();

    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-edited",
        None,
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let record = manifest_text(&w);
    let record = record.split("[forks.skill.gh-edited]").nth(1).unwrap();
    assert!(
        record.contains(&format!("commit = \"{one}\"")),
        "the record carries the captured harness's commit, not another tool's: {record}"
    );
}

/// The copy's frontmatter is rewritten one line at a time: spaces before
/// the colon, a quoted name, CRLF endings and a `...` terminator all keep
/// every other byte, and the name's own line is replaced whole — a comment
/// on it goes with the name it annotated. A name no one line carries
/// refuses the fork.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_rewrites_the_copys_name_line() {
    let cases = [
        (
            "---\nname : gh\ndescription: d\n---\nBody.\n",
            "---\nname: gh-edited\ndescription: d\n---\nBody.\n",
        ),
        (
            "---\r\nname: gh\r\ndescription: d\r\n---\r\nBody.\r\n",
            "---\r\nname: gh-edited\r\ndescription: d\r\n---\r\nBody.\r\n",
        ),
        (
            "---\nname: gh # mine\n...\nBody.\n",
            "---\nname: gh-edited\n...\nBody.\n",
        ),
        (
            "---\nname: \"gh\"\n---\nBody.\n",
            "---\nname: gh-edited\n---\nBody.\n",
        ),
        (
            "---\nname: \"gh\" # package\n---\nBody.\n",
            "---\nname: gh-edited\n---\nBody.\n",
        ),
        (
            "---\nname: gh\n  # note\n---\nBody.\n",
            "---\nname: gh-edited\n  # note\n---\nBody.\n",
        ),
        // A frontmatter without a name gets one, exactly as rendering
        // would give it one.
        (
            "---\ndescription: d\n---\nBody.\n",
            "---\nname: gh-edited\ndescription: d\n---\nBody.\n",
        ),
    ];
    for (text, want) in cases {
        let (w, _one, _two) = edited_world();
        fs::write(skill_file(&w), text).unwrap();
        let plan = fork::fork_beside(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "gh",
            HarnessId::Claude,
            "gh-edited",
            None,
        )
        .unwrap();
        apply::execute(&w.env, &plan).unwrap();
        let own =
            fs::read_to_string(w.home.join("app/.kendex-local/skills/gh-edited/SKILL.md")).unwrap();
        assert_eq!(own, want);
    }

    for (text, problem) in [
        (
            "---\nname: |\n  gh\n---\nBody.\n",
            "runs on past its own line",
        ),
        ("---\nname: gh\nname: gh\n---\nBody.\n", "names it twice"),
    ] {
        let (w, _one, _two) = edited_world();
        fs::write(skill_file(&w), text).unwrap();
        let before = manifest_text(&w);
        let refused = fork::fork_beside(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "gh",
            HarnessId::Claude,
            "gh-edited",
            None,
        )
        .unwrap_err();
        assert!(
            matches!(&refused, CoreError::ForkNameUnusable { problem: said, .. }
                if said.contains(problem)),
            "the refusal says which shape the file is in — {text:?}: {refused:?}"
        );
        assert_eq!(manifest_text(&w), before);
    }
}

/// A skill whose frontmatter carries an explicit YAML key right under its
/// name. Both readers take the document and it installs with nothing said
/// about it, so a fork takes it too: the name is whole on its own line,
/// and the entry below it is not this name's business. The key must sit
/// immediately under `name`, the only position the reading looks at.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_takes_a_name_followed_by_an_explicit_key() {
    let w = world();
    let gh = w.upstream.join("skills/gh/SKILL.md");
    fs::create_dir_all(gh.parent().unwrap()).unwrap();
    fs::write(
        &gh,
        "---\nname: gh\n? extra\n: value\ndescription: about gh\n---\nUpstream.\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    let installed = skill_file(&w);
    assert!(
        installed.is_file(),
        "the fixture proves nothing unless the skill installs"
    );
    fs::write(
        &installed,
        "---\nname: gh\n? extra\n: value\ndescription: mine\n---\nMy fork.\n",
    )
    .unwrap();

    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-mine",
        None,
    )
    .unwrap_or_else(|error| panic!("a fork of a skill the loader takes was refused: {error}"));
    apply::execute(&w.env, &plan).unwrap();
    let own = fs::read_to_string(w.home.join("app/.kendex-local/skills/gh-mine/SKILL.md")).unwrap();
    assert!(own.contains("name: gh-mine"), "{own}");
    assert!(
        own.contains("? extra"),
        "the entry below it is untouched: {own}"
    );
}
