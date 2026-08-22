//! Which way out the CLI prints for an item whose files are already there,
//! and whether following it works. Every offer here is run as it was
//! printed and the state checked afterwards: a row that advertises a
//! command nobody has run is how a way out that trashes the reader's files
//! ships, and the state it lands on can be worse than the one it answered.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn plan(home: &Path, project: &Path) -> String {
    said(&kendex(home, project, &["apply", "--plan"]))
}

/// The offer the plan just printed, word for word.
#[allow(clippy::expect_used)]
fn offer(planned: &str) -> String {
    planned
        .lines()
        .find_map(|line| line.trim().strip_prefix("to keep those files: "))
        .expect("the plan offered a way out that keeps the files")
        .to_owned()
}

/// Run the offer exactly as printed. Reading the command back off the
/// output is the point: a test that retypes it proves the two agree only
/// with each other.
#[allow(clippy::unwrap_used)]
fn follow(home: &Path, project: &Path, planned: &str) -> Output {
    let offered = offer(planned);
    let typed = offered
        .strip_prefix("kendex ")
        .unwrap_or_else(|| panic!("'{offered}' is not something a reader could type"));
    let args: Vec<&str> = typed.split_whitespace().collect();
    let run = kendex(home, project, &args);
    assert!(
        run.status.success(),
        "following '{offered}' failed: {}",
        said(&run)
    );
    run
}

/// Every place the skill sits reads the kept content, nothing is left
/// dangling, and the plan afterwards is done asking — except for whatever
/// this offer was never about, which the caller names.
#[allow(clippy::unwrap_used)]
fn settled(home: &Path, project: &Path, at: &[&str], body: &str, still_waiting: &[&str]) {
    for place in at {
        let path = project.join(place);
        assert!(
            !path.is_symlink() || path.exists(),
            "{place} was left pointing at nothing"
        );
        assert!(
            fs::read_to_string(path.join("SKILL.md"))
                .unwrap_or_default()
                .contains(body),
            "{place} does not read the files that were kept"
        );
    }
    let after = plan(home, project);
    assert!(
        !after.contains("to keep those files:"),
        "the offer was followed and is still being offered: {after}"
    );
    for waiting in still_waiting {
        assert!(
            after.contains(waiting),
            "a decision this offer was not about went quiet: {after}"
        );
    }
    if still_waiting.is_empty() {
        assert!(
            after.contains("nothing to do") && !after.contains("conflict:"),
            "settled once, and still asking: {after}"
        );
    }
}

/// Point the declaration at a different set of tools.
#[allow(clippy::unwrap_used)]
fn retarget(project: &Path, tools: &str) {
    let toml = fs::read_to_string(project.join("kendex.toml")).unwrap();
    let line = toml
        .lines()
        .find(|line| line.starts_with("harnesses = "))
        .unwrap()
        .to_owned();
    fs::write(
        project.join("kendex.toml"),
        toml.replace(&line, &format!("harnesses = {tools}")),
    )
    .unwrap();
}

/// A project asking two tools for one skill, and what each tool has at its
/// own place.
#[allow(clippy::unwrap_used)]
fn project_with(home: &Path, tools: &str, method: &str) -> PathBuf {
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = {tools}\nmethod = \"{method}\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    project
}

#[allow(clippy::unwrap_used)]
fn folder_at(path: &Path, body: &str) {
    fs::create_dir_all(path).unwrap();
    fs::write(
        path.join("SKILL.md"),
        format!("---\nname: deploy\ndescription: ship it\n---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn link_at(path: &Path, target: &Path) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(target, path).unwrap();
}

/// One item blocked for two tools, each holding its own copy. One offer
/// naming both, because keeping them one command at a time lands each
/// tool's copy in the local source on top of the last and leaves the
/// declaration pinned to the first.
#[test]
#[allow(clippy::unwrap_used)]
fn two_tools_holding_one_item_are_kept_by_one_offer() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
    folder_at(&project.join(".claude/skills/deploy"), "Mine.");
    folder_at(&project.join(".agents/skills/deploy"), "Mine.");

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "kendex adopt skill deploy --harness claude --harness codex"
    );

    follow(home, &project, &planned);
    settled(
        home,
        &project,
        &[".claude/skills/deploy", ".agents/skills/deploy"],
        "Mine.",
        &[],
    );
}

/// A file where a folder goes is files kendex did not write, and the
/// replacement handles it — but adoption reads a skill's position as a
/// Adoption reads one tool's position, and left unsaid it reads Claude
/// Code's. A conflict on any other tool was directing the reader at a
/// place that is not the one blocked — so the offer names the tool, and
/// following it settles the item.
#[test]
#[allow(clippy::unwrap_used)]
fn one_tool_blocked_is_kept_through_the_tool_that_is_blocked() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"opencode\"]", "copy");
    folder_at(&project.join(".opencode/skills/deploy"), "The one before.");

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "kendex adopt skill deploy --harness opencode"
    );

    follow(home, &project, &planned);
    settled(
        home,
        &project,
        &[".opencode/skills/deploy"],
        "The one before.",
        &[],
    );
}

/// The same folder, with no declared tool sitting at the link that reads
/// it. Adoption works at a tool's own place, and every tool here has an
/// empty one — so the row says the way out that does work rather than a
/// An item can be blocked for one tool and edited under another, and the two
/// conflicts come out in whichever order the tools are listed. The way out
/// of the hand-made files has to be said either way: printed only when it
/// happens to come last, a reader whose tools are listed the other way is
/// left the exit that sends those files to the trash and nothing else.
#[test]
#[allow(clippy::unwrap_used)]
fn hand_made_files_beside_an_edited_install_keep_their_offer() {
    for tools in ["[\"codex\", \"claude\"]", "[\"claude\", \"codex\"]"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let project = project_with(home, "[\"claude\"]", "copy");
        assert!(
            kendex(home, &project, &["apply", "-y"]).status.success(),
            "{tools}"
        );
        folder_at(&project.join(".claude/skills/deploy"), "Edited by hand.");
        retarget(&project, tools);
        folder_at(&project.join(".agents/skills/deploy"), "By hand.");

        let planned = plan(home, &project);
        assert!(
            planned.contains("edited on disk"),
            "the other tool's edit is the second conflict: {planned}"
        );
        assert_eq!(
            offer(&planned),
            "kendex adopt skill deploy --harness codex",
            "listed as {tools}, the way out went missing: {planned}"
        );

        follow(home, &project, &planned);
        settled(
            home,
            &project,
            &[".agents/skills/deploy"],
            "By hand.",
            // The edit under the other tool is its own decision, and this
            // offer was never about it.
            &["conflict: skill deploy for Claude Code"],
        );
    }
}

/// A shape adoption cannot take, beside one it can. Keeping is one move for
/// the whole item, so an offer that quietly drops the place it cannot take
/// settles the rest and rewrites the declaration around them — leaving that
/// place blocked with the item no longer its tool's. Neither exit fits, and
/// The exits are what a reader types next, so they carry the scope they
/// were read in. Printed while looking at the global scope without it,
mod refusals;
mod shared;

/// The other exit on the same shape. An edit beside the hand-made files is
/// a decision of its own — it never takes the take-over away, and the
/// replacement settles the files it is about while the edit keeps waiting.
#[test]
#[allow(clippy::unwrap_used)]
fn hand_made_files_beside_an_edited_install_are_still_replaceable() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\"]", "copy");
    assert!(kendex(home, &project, &["apply", "-y"]).status.success());
    folder_at(&project.join(".claude/skills/deploy"), "Edited by hand.");
    retarget(&project, "[\"claude\", \"codex\"]");
    folder_at(&project.join(".agents/skills/deploy"), "By hand.");

    let planned = plan(home, &project);
    assert!(
        planned.contains("kendex apply --replace-unmanaged"),
        "the take-over was not offered beside an edit: {planned}"
    );

    let taken = kendex(home, &project, &["apply", "-y", "--replace-unmanaged"]);
    assert!(
        taken.status.success(),
        "an edit beside the files refused the take-over: {}",
        said(&taken)
    );
    assert!(
        fs::read_to_string(project.join(".agents/skills/deploy/SKILL.md"))
            .unwrap()
            .contains("Upstream."),
        "the files it was about were not replaced"
    );
    let after = plan(home, &project);
    assert!(
        after.contains("edited on disk"),
        "the edit is still its own decision: {after}"
    );
}

/// The hand-made sharing layout again, with the copy method: one real
/// folder at one tool's place and the other reading it through a link.
/// It is one folder, so the two rows are one answer — not two copies to
/// choose between.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_shared_by_hand_is_kept_whichever_method_is_declared() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project_with(home, "[\"claude\", \"codex\"]", "copy");
    let folder = project.join(".claude/skills/deploy");
    folder_at(&folder, "Shared by hand.");
    link_at(&project.join(".agents/skills/deploy"), &folder);

    let planned = plan(home, &project);
    assert_eq!(
        offer(&planned),
        "kendex adopt skill deploy --harness claude --harness codex --harness pi",
        "{planned}"
    );

    follow(home, &project, &planned);
    settled(
        home,
        &project,
        &[".claude/skills/deploy", ".agents/skills/deploy"],
        "Shared by hand.",
        &[],
    );
}
