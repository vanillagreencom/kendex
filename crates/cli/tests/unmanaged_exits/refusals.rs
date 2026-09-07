//! The blocked shapes with no way to keep the files, and the exits that
//! have to name the scope they were read in. Every offer here is checked
//! against what a reader could actually run.

use crate::test_util::{rooted, source_path};

use std::fs;

use super::{folder_at, kendex, link_at, offer, plan, project_with, said};

/// The blocked shapes with no way to keep the files. Adoption reads a
/// skill's position as a folder and works at a tool's own place, and
/// keeping is one move for the whole item, so every shape here prints the
/// way out that does work rather than a command that would error or settle
/// half the item: a file where a folder goes (the replacement handles it);
/// a link no declared tool sits at; a shape adoption cannot take beside one
/// it can; a folder that is not a skill (kept, it would go to the trash for
/// a source with nothing to give); a hard conflict beside the files (a link
/// kendex will not touch takes both exits with it); a place adoption cannot
/// enter beside one it can; content under both spellings at once (a later
/// switch would read what is left as kendex's own); a directory wearing the
/// marker's name (the capture reads the marker as a file). One row per
/// shape: the layout planted, the conflict head the plan prints, and, where
/// a row has one, whether the scope-wide replacement is offered beside the
/// line and a file the planning must leave alone.
#[test]
#[allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    reason = "one table: eight planted shapes judged by one plan call, each row a layout of its own"
)]
fn a_shape_with_no_way_to_keep_the_files_is_told_to_move_them() {
    type Plant = fn(&std::path::Path, &std::path::Path) -> Option<std::path::PathBuf>;
    type Row = (
        &'static str,
        &'static str,
        &'static str,
        Plant,
        &'static str,
        Option<bool>,
    );
    let rows: [Row; 8] = [
        (
            "a file where a folder goes",
            "[\"claude\", \"codex\"]",
            "symlink",
            |_home, project| {
                fs::create_dir_all(project.join(".claude/skills")).unwrap();
                fs::write(
                    project.join(".claude/skills/deploy"),
                    "laid out by the tool that came before",
                )
                .unwrap();
                None
            },
            "conflict: skill deploy",
            Some(true),
        ),
        (
            "a link no declared tool sits at",
            "[\"claude\"]",
            "symlink",
            |home, project| {
                let elsewhere = home.join("shared/deploy");
                folder_at(&elsewhere, "Kept somewhere else.");
                link_at(&project.join(".agents/skills/deploy"), &elsewhere);
                Some(elsewhere.join("SKILL.md"))
            },
            "conflict: skill deploy",
            None,
        ),
        (
            "a shape that cannot be kept beside one that can",
            "[\"claude\", \"codex\"]",
            "copy",
            |_home, project| {
                folder_at(&project.join(".claude/skills/deploy"), "By hand.");
                let wrong = project.join(".agents/skills/deploy");
                fs::create_dir_all(wrong.parent().unwrap()).unwrap();
                fs::write(&wrong, "not a folder").unwrap();
                None
            },
            "conflict: skill deploy",
            None,
        ),
        (
            "a folder that is not a skill",
            "[\"claude\"]",
            "copy",
            |_home, project| {
                let here = project.join(".claude/skills/deploy");
                fs::create_dir_all(&here).unwrap();
                fs::write(here.join("notes.md"), "somebody else's folder").unwrap();
                None
            },
            "conflict: skill deploy",
            None,
        ),
        (
            "a hard conflict beside the files",
            "[\"claude\", \"codex\"]",
            "copy",
            |home, project| {
                folder_at(&project.join(".claude/skills/deploy"), "By hand.");
                let elsewhere = home.join("notes");
                fs::create_dir_all(&elsewhere).unwrap();
                fs::write(elsewhere.join("read-me.txt"), "not a skill").unwrap();
                link_at(&project.join(".agents/skills/deploy"), &elsewhere);
                None
            },
            "conflict: skill deploy",
            Some(false),
        ),
        (
            "a place adoption cannot enter beside one it can",
            "[\"claude\", \"codex\"]",
            "copy",
            |_home, project| {
                folder_at(&project.join(".claude/skills/deploy"), "By hand.");
                let here = project.join(".agents/skills/deploy");
                fs::create_dir_all(&here).unwrap();
                fs::write(here.join("notes.md"), "somebody else's folder").unwrap();
                None
            },
            "conflict: skill deploy",
            None,
        ),
        (
            "content under both spellings at once",
            "[\"claude\"]",
            "copy",
            |home, project| {
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
                Some(dir.join("scout.md.disabled"))
            },
            "conflict: agent scout",
            None,
        ),
        (
            "a directory named like the marker",
            "[\"claude\"]",
            "copy",
            |_home, project| {
                let here = project.join(".claude/skills/deploy");
                fs::create_dir_all(here.join("SKILL.md")).unwrap();
                fs::write(here.join("SKILL.md/notes.txt"), "not a marker").unwrap();
                None
            },
            "conflict: skill deploy",
            None,
        ),
    ];
    for (shape, harnesses, method, plant, head, replacement_offered) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let home = home.as_path();
        let project = project_with(home, harnesses, method);
        let untouched = plant(home, &project);
        let before = untouched.as_ref().map(|path| fs::read(path).unwrap());

        let planned = plan(home, &project);

        assert!(planned.contains(head), "{shape}: {planned}");
        assert_eq!(
            offer(&planned),
            "move them somewhere else first",
            "{shape}: {planned}"
        );
        if let Some(offered) = replacement_offered {
            assert_eq!(
                planned.contains("--replace-unmanaged"),
                offered,
                "{shape}: the scope-wide replacement: {planned}"
            );
        }
        if let (Some(path), Some(before)) = (untouched, before) {
            assert_eq!(
                fs::read(&path).unwrap(),
                before,
                "{shape}: planning touched {}",
                path.display()
            );
        }
    }
}

/// The exits are what a reader types next, so they carry the scope they
/// were read in. Printed while looking at the global scope without it,
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

/// Whether the scope-wide flag is offered. It answers for every item it
/// sweeps up or for none of them, so an item it takes and can only half
/// settle withholds it (the per-item ways out still stand); an item the
/// flag never reaches (a link kendex will not write over) is no reason to
/// withhold it; and a person's own edit never takes the item's other exits
/// away, which is the invariant `DriftCause::is_own_decision` exists to
/// keep, held in the hardest shape the rows allow: one item carrying an
/// edit at one tool and a stranger's files at another, beside an item
/// wholly replaceable at two places. One row per shape.
#[test]
#[allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    reason = "one table: three planted shapes judged by one plan call, each row a layout of its own"
)]
fn the_scope_wide_flag_is_withheld_only_by_a_row_the_sweep_would_refuse_on() {
    type Plant = fn(&std::path::Path, &std::path::Path);
    type Row = (
        &'static str,
        &'static str,
        Plant,
        &'static [&'static str],
        bool,
    );
    let rows: [Row; 3] = [
        (
            "a second item with one replaceable copy and one shared folder",
            "[\"claude\", \"codex\"]",
            |home, project| {
                folder_at(&project.join(".claude/skills/deploy"), "By hand.");
                folder_at(&project.join(".agents/skills/deploy"), "By hand.");
                let elsewhere = home.join("shared/lint");
                folder_at(&elsewhere, "Shared by hand.");
                let text = fs::read_to_string(project.join("kendex.toml")).unwrap();
                fs::write(
                    project.join("kendex.toml"),
                    text.replace(
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
            },
            &[],
            false,
        ),
        (
            "a second item that is only a link somebody made",
            "[\"claude\"]",
            |home, project| {
                folder_at(&project.join(".claude/skills/deploy"), "By hand.");
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
            },
            &[],
            true,
        ),
        (
            "an edit at one tool and a stranger's files at another, beside a replaceable item",
            "[\"claude\"]",
            |home, project| {
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
                assert!(kendex(home, project, &["apply", "-y"]).status.success());
                fs::write(
                    project.join(".claude/skills/lint/SKILL.md"),
                    "---\nname: lint\ndescription: lints it\n---\nEdited by hand.\n",
                )
                .unwrap();
                // Codex joins, with a stranger's files already at lint's place
                // there, and deploy is declared beside it and wholly replaceable.
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
                folder_at(&project.join(".claude/skills/deploy"), "By hand.");
                folder_at(&project.join(".agents/skills/deploy"), "By hand.");
            },
            // The fixture proves nothing unless lint carries both halves: the
            // person's edit at one tool, and a stranger's files at another.
            &[
                "conflict: skill lint for Claude Code: edited on disk",
                "conflict: skill lint for Codex",
                "already holds files kendex did not write",
            ],
            true,
        ),
    ];
    for (shape, harnesses, plant, halves, offered) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let home = home.as_path();
        let project = project_with(home, harnesses, "copy");
        plant(home, &project);

        let planned = plan(home, &project);

        // Every row carries lint's conflict and deploy's: the flag is decided
        // over both, and the per-item ways out are untouched either way.
        assert!(
            planned.contains("conflict: skill lint"),
            "{shape}: {planned}"
        );
        assert!(
            planned.contains("conflict: skill deploy"),
            "{shape}: {planned}"
        );
        for half in halves {
            assert!(
                planned.contains(half),
                "{shape}: {half} is missing: {planned}"
            );
        }
        assert_eq!(
            planned.contains("--replace-unmanaged"),
            offered,
            "{shape}: {planned}"
        );
    }
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
