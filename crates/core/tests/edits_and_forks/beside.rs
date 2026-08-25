//! Installing beside: the edited copy becomes the user's own package under
//! a new name and the source's version comes back under the old one — with
//! everything proven before anything is written.

use std::fs;
use std::path::Path;

use kendex_core::error::CoreError;

use super::*;

#[allow(clippy::unwrap_used)]
fn head_commit(dir: &Path) -> String {
    let output = Hardened::git(&["rev-parse", "HEAD"], Some(dir))
        .run()
        .unwrap();
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

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
    apply::execute(&w.env, &plan, None).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

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

#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_name_the_scope_already_uses() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    write_skill(&w.upstream, "docs", "Docs.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.docs]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    fs::write(skill_file(&w), "edited").unwrap();

    let beside = |new_name: &str| {
        fork::fork_beside(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "gh",
            HarnessId::Claude,
            new_name,
            None,
        )
        .unwrap_err()
    };
    let taken = beside("docs");
    assert!(
        matches!(taken, CoreError::SourceCollision { .. }),
        "{taken:?}"
    );

    let local = w.home.join("app/.kendex-local/skills/mine");
    fs::create_dir_all(&local).unwrap();
    fs::write(local.join("SKILL.md"), "---\nname: mine\n---\nTheirs.\n").unwrap();
    let stranger = beside("mine");
    assert!(
        matches!(stranger, CoreError::SourceCollision { .. }),
        "{stranger:?}"
    );
    assert_eq!(
        fs::read_to_string(local.join("SKILL.md")).unwrap(),
        "---\nname: mine\n---\nTheirs.\n"
    );

    let bad = beside("a/b/c");
    assert!(matches!(bad, CoreError::ForkNameUnusable { .. }), "{bad:?}");
}

/// A derived install — a dependency or bundle member — has a lock entry
/// but no declaration of its own; its name is no less taken. A refusal
/// here writes nothing: the manifest stays byte-identical and the
/// dependency's install is untouched.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_name_an_installed_dependency_holds() {
    let w = world();
    let gh = w.upstream.join("skills/gh/SKILL.md");
    fs::create_dir_all(gh.parent().unwrap()).unwrap();
    fs::write(
        &gh,
        "---\nname: gh\ndescription: about gh\ndependencies:\n  required: [helper]\n---\nParent.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "helper", "Helper.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    let helper = w.home.join("app/.agents/skills/helper/SKILL.md");
    assert!(helper.is_file(), "dependency installed without declaration");
    fs::write(skill_file(&w), "---\nname: gh\n---\nMine.\n").unwrap();
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "helper",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::SourceCollision { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(fs::read_to_string(&helper).unwrap().contains("Helper."));
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("Mine.")
    );
}

/// Something already sitting where the fork would render — a directory
/// kendex never wrote — would make the render pass refuse after the fork
/// was recorded. It refuses up front instead, touching nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_destination_an_unmanaged_file_occupies() {
    let (w, _one, _two) = edited_world();
    let stray = w.home.join("app/.agents/skills/gh-mine");
    fs::create_dir_all(&stray).unwrap();
    fs::write(stray.join("notes.md"), "not kendex's").unwrap();
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "gh-mine",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(!w.home.join("app/.kendex-local/skills/gh-mine").exists());
    assert_eq!(
        fs::read_to_string(stray.join("notes.md")).unwrap(),
        "not kendex's"
    );
}

/// A name a target tool's loader would reject records a fork and then
/// installs nothing — so the loader's own check runs first, and the
/// refusal names it.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_name_a_target_loader_refuses() {
    let (w, _one, _two) = edited_world();
    let before = manifest_text(&w);
    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "a..b",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(!w.home.join("app/.kendex-local/skills/a..b").exists());
}

#[allow(clippy::unwrap_used)]
fn write_agent(dir: &Path, name: &str, body: &str) {
    let agents = dir.join("agents");
    fs::create_dir_all(&agents).unwrap();
    fs::write(
        agents.join(format!("{name}.md")),
        format!("---\nname: {name}\ndescription: agent {name}\n---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn manifest_text(w: &World) -> String {
    fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap()
}

/// A world with `gh` edited on disk and a newer upstream the mirror knows.
#[allow(clippy::unwrap_used)]
fn edited_world() -> (World, String, String) {
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
    sync_and_apply(&w);
    (w, one, two)
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
    apply::execute(&w.env, &plan, None).unwrap();
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
    apply::execute(&w.env, &plan, None).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

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
    apply::execute(&w.env, &plan, None).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

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

/// Names that fold together on a case- or composition-folding filesystem
/// are one slot: the planner would refuse both and sweep the old one, so
/// the fork refuses first. A dangling link is a taken slot too.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_and_rename_refuse_names_that_fold_onto_a_neighbour() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    write_skill(&w.upstream, "Docs", "Docs.");
    write_skill(&w.upstream, "caf\u{e9}", "Composed.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.Docs]\nsource = \"cat\"\n\n[skills.\"caf\u{e9}\"]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    fs::write(skill_file(&w), "---\nname: gh\n---\nMine.\n").unwrap();
    let before = manifest_text(&w);
    let beside = |new_name: &str| {
        fork::fork_beside(
            &w.env,
            &w.scope,
            ItemKind::Skill,
            "gh",
            HarnessId::Claude,
            new_name,
            None,
        )
        .unwrap_err()
    };
    let collides = |error: CoreError| {
        assert!(
            matches!(error, CoreError::SourceCollision { .. }),
            "{error:?}"
        );
    };

    // Case, and the decomposed spelling of a composed name.
    collides(beside("docs"));
    collides(beside("cafe\u{301}"));
    // A local-source sibling that folds the same way, and a dangling link.
    let local = w.home.join("app/.kendex-local/skills");
    fs::create_dir_all(local.join("Gh-Mine")).unwrap();
    collides(beside("gh-mine"));
    std::os::unix::fs::symlink("nowhere", local.join("gh-linked")).unwrap();
    collides(beside("gh-linked"));
    assert_eq!(manifest_text(&w), before);

    // The same rule guards a rename.
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();
    let renamed = fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "DOCS").unwrap_err();
    collides(renamed);
    let linked =
        fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "gh-linked").unwrap_err();
    collides(linked);
}

/// A namespaced declaration renders under a separator; a plain name that
/// spells the same rendered path is the same slot.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_name_that_renders_like_a_namespaced_neighbour() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skills.\"tools/lint\"]\nsource = \"local\"\n",
    );
    let local = w.home.join("app/.kendex-local/skills/tools/lint");
    fs::create_dir_all(&local).unwrap();
    fs::write(local.join("SKILL.md"), "---\nname: lint\n---\nLint.\n").unwrap();
    sync_and_apply(&w);
    fs::write(skill_file(&w), "---\nname: gh\n---\nMine.\n").unwrap();

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "tools-lint",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::SourceCollision { .. }),
        "{refused:?}"
    );
}

/// A local-source sibling folding onto a namespaced name's own directory
/// slot is a collision too: the scan compares the slot's leaf against its
/// neighbours, not the full `plugin/item` spelling against a bare leaf.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_a_folding_sibling_of_a_namespaced_name() {
    let (w, _one, _two) = edited_world();
    fs::create_dir_all(w.home.join("app/.kendex-local/skills/ns/GH")).unwrap();
    let before = manifest_text(&w);

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        HarnessId::Claude,
        "ns/gh",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::SourceCollision { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
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
    apply::execute(&w.env, &plan, None).unwrap();
    let record = manifest_text(&w);
    let record = record.split("[forks.skill.gh-edited]").nth(1).unwrap();
    assert!(
        record.contains(&format!("commit = \"{one}\"")),
        "the record carries the captured harness's commit, not another tool's: {record}"
    );
}

/// The copy's frontmatter is rewritten by span: a quoted name, a comment,
/// spaces before the colon, CRLF endings, and a `...` terminator all keep
/// every other byte; a name no single scalar can replace refuses the fork.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_renames_the_copy_by_its_name_span() {
    let cases = [
        (
            "---\nname : gh\ndescription: d\n---\nBody.\n",
            "---\nname : gh-edited\ndescription: d\n---\nBody.\n",
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
            "---\nname: gh-edited # package\n---\nBody.\n",
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
        apply::execute(&w.env, &plan, None).unwrap();
        let own =
            fs::read_to_string(w.home.join("app/.kendex-local/skills/gh-edited/SKILL.md")).unwrap();
        assert_eq!(own, want);
    }

    for text in [
        "---\nname: |\n  gh\n---\nBody.\n",
        "---\nname: gh\nname: gh\n---\nBody.\n",
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
            matches!(refused, CoreError::ForkNameUnusable { .. }),
            "{text:?}: {refused:?}"
        );
        assert_eq!(manifest_text(&w), before);
    }
}
