//! Which way out the CLI prints for an item whose files are already there,
//! and whether following it works. Every offer here is run as it was
//! printed and the state checked afterwards: a row that advertises a
//! command nobody has run is how a way out that trashes the reader's files
//! ships, and the state it lands on can be worse than the one it answered.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
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
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = {tools}\nmethod = \"{method}\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            source_path(&catalog)
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

/// Which way out is printed for files already at an item's place, and that
/// following it keeps them. One row per shape: two tools each holding a
/// copy are kept by one offer naming both, because keeping them one
/// command at a time lands each tool's copy in the local source on top of
/// the last and leaves the declaration pinned to the first; adoption reads
/// one tool's position, and left unsaid it reads Claude Code's, so a
/// conflict on any other tool names the tool it is blocked for; one folder
/// shared by hand (a real folder at one tool's place, the other reading it
/// through a link somebody made) is one answer whichever method the
/// declaration names, named for every tool adoption can act through rather
/// than the tool a row happens to be about, the folder measured like any
/// other content and never offered the replacement (the files are not at
/// the link's position, and writing over it breaks the sharing); and a
/// folder somewhere neither tool would look is reached through the one
/// tool whose own place is the link, since naming the other, which has
/// nothing there, would error on the spot. Each row: the tools declared,
/// the method, what is planted, the place the reader is told about, the
/// offer word for word, whether the scope-wide replacement is offered
/// beside it, and the places that must read the kept files afterwards.
#[test]
#[allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    reason = "one table: five planted layouts, each followed as printed"
)]
fn the_offer_that_keeps_the_files_is_the_one_that_settles_them() {
    type Plant = fn(&Path, &Path);
    type Row = (
        &'static str,
        &'static str,
        &'static str,
        Plant,
        &'static str,
        &'static str,
        bool,
        &'static [&'static str],
    );
    const EVERY_TOOL: &str = "kendex adopt skill deploy --harness claude --harness codex \
         --harness opencode --harness cursor --harness pi --harness gemini --harness copilot \
         --harness antigravity";
    let rows: [Row; 5] = [
        (
            "two tools, each holding a copy",
            "[\"claude\", \"codex\"]",
            "copy",
            |_, project| {
                folder_at(&project.join(".claude/skills/deploy"), "By hand.");
                folder_at(&project.join(".agents/skills/deploy"), "By hand.");
            },
            ".claude/skills/deploy",
            "kendex adopt skill deploy --harness claude --harness codex",
            true,
            &[".claude/skills/deploy", ".agents/skills/deploy"],
        ),
        (
            "one tool blocked, not Claude Code",
            "[\"opencode\"]",
            "copy",
            |_, project| folder_at(&project.join(".opencode/skills/deploy"), "By hand."),
            ".opencode/skills/deploy",
            "kendex adopt skill deploy --harness opencode",
            true,
            &[".opencode/skills/deploy"],
        ),
        (
            "one folder shared by hand, copy declared",
            "[\"claude\", \"codex\"]",
            "copy",
            |_, project| {
                let folder = project.join(".claude/skills/deploy");
                folder_at(&folder, "By hand.");
                link_at(&project.join(".agents/skills/deploy"), &folder);
            },
            ".claude/skills/deploy",
            EVERY_TOOL,
            false,
            &[".claude/skills/deploy", ".agents/skills/deploy"],
        ),
        (
            "one folder shared by hand, symlink declared",
            "[\"claude\", \"codex\"]",
            "symlink",
            |_, project| {
                let folder = project.join(".claude/skills/deploy");
                folder_at(&folder, "By hand.");
                link_at(&project.join(".agents/skills/deploy"), &folder);
            },
            ".claude/skills/deploy",
            EVERY_TOOL,
            false,
            &[".claude/skills/deploy", ".agents/skills/deploy"],
        ),
        (
            "the folder outside every tool, linked at one",
            "[\"claude\", \"codex\"]",
            "symlink",
            |home, project| {
                let elsewhere = home.join("shared/deploy");
                folder_at(&elsewhere, "By hand.");
                link_at(&project.join(".agents/skills/deploy"), &elsewhere);
            },
            "shared/deploy",
            "kendex adopt skill deploy --harness codex --harness opencode --harness cursor \
             --harness pi --harness gemini --harness copilot --harness antigravity",
            false,
            &[".claude/skills/deploy", ".agents/skills/deploy"],
        ),
    ];
    for (shape, tools, method, plant, named, want, replaceable, kept_at) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let home = home.as_path();
        let project = project_with(home, tools, method);
        plant(home, &project);

        let planned = plan(home, &project);
        assert!(
            planned.contains(named),
            "{shape}: the place the reader decides about is not named: {planned}"
        );
        assert!(
            planned.contains("differs from the catalog in 1 file: SKILL.md"),
            "{shape}: the folder was never compared with the install it blocks: {planned}"
        );
        assert_eq!(
            planned.contains("--replace-unmanaged"),
            replaceable,
            "{shape}: {planned}"
        );
        assert_eq!(offer(&planned), want, "{shape}: {planned}");

        follow(home, &project, &planned);
        settled(home, &project, kept_at, "By hand.", &[]);
        let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
        assert!(
            !manifest.contains("[skills.deploy]\nsource = \"local\"\nharnesses"),
            "{shape}: a tool that was blocked a moment ago lost the skill:\n{manifest}"
        );
    }
}

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

mod refusals;

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
