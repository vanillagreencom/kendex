//! The blocked shapes with no way to keep the files, and the exits that
//! have to name the scope they were read in. Every offer here is checked
//! against what a reader could actually run.

use crate::test_util::{rooted, source_path};

use std::fs;

use super::{folder_at, kendex, link_at, offer, plan, project_with, said};

/// folder, so the keep line must not be printed here.
#[test]
#[allow(clippy::unwrap_used)]
fn a_file_where_a_folder_goes_is_not_offered_the_adopt() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "symlink");
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    fs::write(
        project.join(".claude/skills/deploy"),
        "laid out by the tool that came before",
    )
    .unwrap();

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert_eq!(offer(&planned), "move them somewhere else first");
    assert!(
        planned.contains("--replace-unmanaged"),
        "the exit that handles this shape was not offered: {planned}"
    );
}

/// command that would error on the spot.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_no_declared_tool_sits_at_offers_no_command() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "symlink");
    let elsewhere = home.join("shared/deploy");
    folder_at(&elsewhere, "Kept somewhere else.");
    link_at(&project.join(".agents/skills/deploy"), &elsewhere);

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert_eq!(offer(&planned), "move them somewhere else first");
    assert!(
        fs::read_to_string(elsewhere.join("SKILL.md"))
            .unwrap()
            .contains("Kept somewhere else."),
        "planning touched the folder"
    );
}

/// the row says so.
#[test]
#[allow(clippy::unwrap_used)]
fn a_shape_that_cannot_be_kept_takes_the_whole_item_s_offer_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
    folder_at(&project.join(".claude/skills/deploy"), "By hand.");
    // A plain file where Codex reads a folder: nothing to take into the
    // local source.
    let wrong = project.join(".agents/skills/deploy");
    fs::create_dir_all(wrong.parent().unwrap()).unwrap();
    fs::write(&wrong, "not a folder").unwrap();

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "move them somewhere else first",
        "an offer that settles half the item was printed: {planned}"
    );
}

/// both run against whatever project the terminal happens to be in.
#[test]
#[allow(clippy::unwrap_used)]
fn an_exit_read_in_the_global_scope_says_so() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    // The platform config root the binary itself resolves: macOS reads
    // Library/Application Support and ignores XDG variables entirely.
    #[cfg(target_os = "macos")]
    let global = home.join("Library/Application Support/kendex");
    #[cfg(not(target_os = "macos"))]
    let global = home.join(".config/kendex");
    fs::create_dir_all(&global).unwrap();
    fs::write(
        global.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            source_path(&catalog)
        ),
    )
    .unwrap();
    folder_at(&home.join(".claude/skills/deploy"), "By hand.");

    let planned = said(&kendex(home, home, &["apply", "--plan", "--global"]));
    assert_eq!(
        offer(&planned),
        "kendex adopt skill deploy --harness claude --global"
    );
    assert!(
        planned.contains("kendex apply --replace-unmanaged --global"),
        "the replacement runs against the current project without it: {planned}"
    );
}

/// A folder that is not a skill. Kept, it goes to the trash and the
/// declaration is rewritten around a local source that has nothing to
/// give, so the apply that follows installs nothing — the reader is told
/// their files were kept and they are gone.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_that_is_not_a_skill_is_not_offered_the_keep() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    let here = project.join(".claude/skills/deploy");
    fs::create_dir_all(&here).unwrap();
    fs::write(here.join("notes.md"), "somebody else's folder").unwrap();

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert_eq!(offer(&planned), "move them somewhere else first");
}

/// The scope-wide flag answers for every item it sweeps up or for none of
/// them, so an item it takes and can only half settle refuses the whole
/// run. Offering the command beside a wholly replaceable neighbour would
/// name one that cannot succeed on the scope it is printed under, so it is
/// withheld — while each item's own way out still stands.
#[test]
#[allow(clippy::unwrap_used)]
fn an_item_the_sweep_would_refuse_on_withholds_the_scope_exit() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
    // One item wholly replaceable.
    folder_at(&project.join(".claude/skills/deploy"), "By hand.");
    folder_at(&project.join(".agents/skills/deploy"), "By hand.");
    // A second item with one replaceable copy and one shared folder, which
    // is never written over.
    let elsewhere = home.join("shared/lint");
    folder_at(&elsewhere, "Shared by hand.");
    fs::write(
        project.join("kendex.toml"),
        fs::read_to_string(project.join("kendex.toml"))
            .unwrap()
            .replace(
                "[skills.deploy]\nsource = \"cat\"\n",
                "[skills.deploy]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
            ),
    )
    .unwrap();
    fs::create_dir_all(home.join("catalog/skills/lint")).unwrap();
    fs::write(
        home.join("catalog/skills/lint/SKILL.md"),
        "---\nname: lint\ndescription: lints it\n---\nUpstream.\n",
    )
    .unwrap();
    folder_at(&project.join(".claude/skills/lint"), "By hand.");
    link_at(&project.join(".agents/skills/lint"), &elsewhere);

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill lint"), "{planned}");
    assert!(
        !planned.contains("--replace-unmanaged"),
        "a command that would refuse on this scope was offered: {planned}"
    );
    // The per-item ways out are untouched: only the scope-wide offer goes.
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
}

/// A hard conflict beside files in the way. Both exits act on the whole
/// item and the engine refuses one it could only half settle, so the row
/// carries neither — a link kendex will not touch takes the offer with it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hard_conflict_beside_the_files_takes_both_exits_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
    folder_at(&project.join(".claude/skills/deploy"), "By hand.");
    // Codex's place is a link into somewhere that is not a skill at all,
    // which adoption refuses and replacement never writes over.
    let elsewhere = home.join("notes");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::write(elsewhere.join("read-me.txt"), "not a skill").unwrap();
    link_at(&project.join(".agents/skills/deploy"), &elsewhere);

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert_eq!(offer(&planned), "move them somewhere else first");
    assert!(
        !planned.contains("--replace-unmanaged"),
        "half the item was offered a take-over: {planned}"
    );
}

/// A place adoption cannot enter, beside one it can. Keeping is one move
/// for the whole item, so an offer naming only the tool that works would
/// settle its copy and leave the other blocked with the item no longer
/// its tool's.
#[test]
#[allow(clippy::unwrap_used)]
fn a_place_adoption_cannot_enter_takes_the_offer_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
    folder_at(&project.join(".claude/skills/deploy"), "By hand.");
    // Codex's copy is a folder that is not a skill: adoption has nothing
    // to take there, and the local source would not find it again.
    let here = project.join(".agents/skills/deploy");
    fs::create_dir_all(&here).unwrap();
    fs::write(here.join("notes.md"), "somebody else's folder").unwrap();

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "move them somewhere else first",
        "half the item was offered a keep: {planned}"
    );
}

/// An edit is not files anybody has to move — it is settled by keeping it
/// as a fork or discarding it — so the line about moving files aside does
/// not belong under it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_is_never_told_to_move_files() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    assert!(kendex(home, &project, &["apply", "-y"]).status.success());
    folder_at(&project.join(".claude/skills/deploy"), "Edited by hand.");

    // The same item, pointed at a second catalog: a clash its files have
    // nothing to do with.
    let elsewhere = home.join("second");
    folder_at(&elsewhere.join("skills/deploy"), "Somewhere else.");
    let manifest = project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    let (head, tail) = text.split_once("[install]").unwrap();
    fs::write(
        &manifest,
        format!(
            "{head}[sources.other]\n{}\n\n[install]{}",
            source_path(&elsewhere),
            tail.replace("source = \"cat\"", "source = \"other\"")
        ),
    )
    .unwrap();

    let planned = plan(home, &project);
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert!(
        !planned.contains("to keep those files:"),
        "moving files settles neither of these: {planned}"
    );
}

/// Content under both spellings at once. Keeping would take one and leave
/// the other, and a later switch reads what is left as kendex's own — so
/// the reader settles it rather than being offered half a move.
#[test]
#[allow(clippy::unwrap_used)]
fn content_under_both_spellings_is_never_offered_the_keep() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    fs::create_dir_all(home.join("catalog/agents")).unwrap();
    fs::write(
        home.join("catalog/agents/scout.md"),
        "---\nname: scout\ndescription: looks around\n---\nUpstream.\n",
    )
    .unwrap();
    let manifest = project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        format!("{text}\n[agents.scout]\nsource = \"cat\"\n"),
    )
    .unwrap();
    let dir = project.join(".claude/agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("scout.md"), "on by hand").unwrap();
    fs::write(dir.join("scout.md.disabled"), "off by hand").unwrap();

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "move them somewhere else first",
        "{planned}"
    );
    assert!(
        dir.join("scout.md.disabled").is_file(),
        "both are left where they are"
    );
}

/// An item the flag never reaches is no reason to withhold it. A link
/// kendex will not write over has nothing to take over, so it is never
/// swept up — and the item beside it that does can still say so.
#[test]
#[allow(clippy::unwrap_used)]
fn an_item_the_flag_never_reaches_does_not_withhold_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    folder_at(&project.join(".claude/skills/deploy"), "By hand.");
    // A second item that is only a link somebody made: nothing to replace,
    // so the flag would never touch it.
    fs::create_dir_all(home.join("catalog/skills/lint")).unwrap();
    fs::write(
        home.join("catalog/skills/lint/SKILL.md"),
        "---\nname: lint\ndescription: lints it\n---\nUpstream.\n",
    )
    .unwrap();
    let manifest = project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace(
            "[skills.deploy]\nsource = \"cat\"\n",
            "[skills.deploy]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
        ),
    )
    .unwrap();
    let elsewhere = home.join("notes");
    fs::create_dir_all(&elsewhere).unwrap();
    link_at(&project.join(".claude/skills/lint"), &elsewhere);

    let planned = plan(home, &project);
    assert!(
        planned.contains("kendex apply --replace-unmanaged"),
        "an item the flag never reaches withheld it: {planned}"
    );
}

/// A directory wearing the marker's name. The capture reads the marker as
/// a file, so taking the tree would trash the original for a source with
/// nothing to give back.
#[test]
#[allow(clippy::unwrap_used)]
fn a_directory_named_like_the_marker_is_not_offered_the_keep() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    let here = project.join(".claude/skills/deploy");
    fs::create_dir_all(here.join("SKILL.md")).unwrap();
    fs::write(here.join("SKILL.md/notes.txt"), "not a marker").unwrap();

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "move them somewhere else first",
        "{planned}"
    );
}

/// A person's own edit never takes the item's other exits away, which is
/// the invariant `DriftCause::is_own_decision` exists to keep. The sweep
/// settles a scope whose only unsettleable row is an edit, so withholding
/// the offer there would leave the reader with no printed way to install
/// what kendex.toml asks for: the per-item line offers only the keep.
/// Held in the hardest shape the rows allow: one item carrying an edit at
/// one tool and a stranger's files at another, beside an item wholly
/// replaceable at two places. The fixture asserts both of lint's rows
/// before it reads the offer, because a claude-only install leaves the
/// shared tree Codex reads untouched and it is easy to write the stranger
/// where no tool looks.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_beside_a_replaceable_item_does_not_withhold_the_scope_exit() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let home = home.as_path();
    let project = project_with(home, "[\"claude\"]", "copy");
    fs::create_dir_all(home.join("catalog/skills/lint")).unwrap();
    fs::write(
        home.join("catalog/skills/lint/SKILL.md"),
        "---\nname: lint\ndescription: lints it\n---\nUpstream.\n",
    )
    .unwrap();
    let manifest = project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace(
            "[skills.deploy]\nsource = \"cat\"\n",
            "[skills.lint]\nsource = \"cat\"\n",
        ),
    )
    .unwrap();
    // lint installs for claude alone, and the person edits it.
    assert!(kendex(home, &project, &["apply", "-y"]).status.success());
    fs::write(
        project.join(".claude/skills/lint/SKILL.md"),
        "---\nname: lint\ndescription: lints it\n---\nEdited by hand.\n",
    )
    .unwrap();
    // Codex joins, with a stranger's files already at lint's place there,
    // and deploy is declared beside it and wholly replaceable.
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace(
            "harnesses = [\"claude\"]",
            "harnesses = [\"claude\", \"codex\"]",
        )
        .replace(
            "[skills.lint]\nsource = \"cat\"\n",
            "[skills.lint]\nsource = \"cat\"\n\n[skills.deploy]\nsource = \"cat\"\n",
        ),
    )
    .unwrap();
    // Codex reads the shared tree, which a claude-only install never
    // wrote, so a stranger there is unmanaged content for Codex alone.
    fs::create_dir_all(project.join(".agents/skills/lint")).unwrap();
    fs::write(
        project.join(".agents/skills/lint/SKILL.md"),
        "---\nname: lint\ndescription: lints it\n---\nSomebody else's.\n",
    )
    .unwrap();
    // deploy is wholly replaceable at both tools' places, so the verdict
    // has two replaceable dead stops of one item to weigh as well.
    folder_at(&project.join(".claude/skills/deploy"), "By hand.");
    folder_at(&project.join(".agents/skills/deploy"), "By hand.");

    let planned = plan(home, &project);
    // The fixture proves nothing unless lint carries both halves: the
    // person's edit at one tool, and a stranger's files at another.
    assert!(
        planned.contains("conflict: skill lint for Claude Code: edited on disk"),
        "the edit half is missing: {planned}"
    );
    assert!(
        planned.contains("conflict: skill lint for Codex")
            && planned.contains("already holds files kendex did not write"),
        "the stranger half is missing: {planned}"
    );
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert!(
        planned.contains("--replace-unmanaged"),
        "an edit is not a row the sweep refuses on: {planned}"
    );
}

/// The offer and the engine, checked against each other on one scope
/// rather than each against itself. A case that pins the CLI's rule
/// against the CLI's rule passes whether or not that rule agrees with the
/// run it advertises, which is how a divergence in either direction lives
/// through a cycle. So each shape here is planned, then the advertised
/// command is actually run: the offer is printed exactly where running it
/// installs what kendex.toml asks for.
///
/// The shapes are the two directions plus the ordinary one. What this
/// cannot reach is a conflict the unflagged pass stops at before looking
/// past it — a stranger's tree in the canonical position with the harness
/// link beside it never inspected — because the blocking row is absent
/// from the plan the CLI reads.
#[test]
#[allow(clippy::unwrap_used)]
fn the_offer_is_printed_exactly_where_the_run_it_names_settles_the_scope() {
    for (shape, build) in [
        ("wholly replaceable", 0),
        ("an edit beside a replaceable item", 1),
        ("a shared folder nothing can settle", 2),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let home = home.as_path();
        let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
        folder_at(&project.join(".claude/skills/deploy"), "By hand.");
        folder_at(&project.join(".agents/skills/deploy"), "By hand.");
        if build == 1 {
            assert!(kendex(home, &project, &["apply", "-y"]).status.success());
            folder_at(&project.join(".claude/skills/deploy"), "Edited by hand.");
        }
        if build == 2 {
            // A second item with one replaceable copy and one shared
            // folder, which is never written over.
            fs::create_dir_all(home.join("catalog/skills/lint")).unwrap();
            fs::write(
                home.join("catalog/skills/lint/SKILL.md"),
                "---\nname: lint\ndescription: lints it\n---\nUpstream.\n",
            )
            .unwrap();
            let manifest = project.join("kendex.toml");
            let text = fs::read_to_string(&manifest).unwrap();
            fs::write(
                &manifest,
                text.replace(
                    "[skills.deploy]\nsource = \"cat\"\n",
                    "[skills.deploy]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
                ),
            )
            .unwrap();
            let elsewhere = home.join("shared/lint");
            folder_at(&elsewhere, "Shared by hand.");
            folder_at(&project.join(".claude/skills/lint"), "By hand.");
            link_at(&project.join(".agents/skills/lint"), &elsewhere);
        }

        let offered = plan(home, &project).contains("--replace-unmanaged");
        let swept = said(&kendex(
            home,
            &project,
            &["apply", "--replace-unmanaged", "-y"],
        ));
        // What the offer promises, read off the scope afterwards rather
        // than off the run's own words: nothing is in the way any more.
        // A run that exits clean having changed nothing has not installed
        // what kendex.toml asks for.
        let after = plan(home, &project);
        let settled = !after.contains("conflict: ");
        assert_eq!(
            offered,
            settled,
            "{shape}: the plan {} the flag, and running it left the scope {}\n\
             --- the run said:\n{swept}\n--- and the scope now:\n{after}",
            if offered { "offered" } else { "withheld" },
            if settled { "settled" } else { "still blocked" },
        );
    }
}
