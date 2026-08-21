//! What the CLI says about files kendex did not write: the two exits out of
//! a declaration blocked by them, and the footnote for content nothing
//! declares at all — listed by `list`, and until now invisible to every
//! command that could say whether it had been looked at.
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
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// A project declaring skill `deploy` from a local catalog, with `deploy`
/// already on disk in the shape an earlier tool left it.
#[allow(clippy::unwrap_used)]
fn migrating_project(home: &Path) -> PathBuf {
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/skills/deploy")).unwrap();
    fs::write(
        project.join(".claude/skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nWritten by the tool that came before.\n",
    )
    .unwrap();
    project
}

#[allow(clippy::unwrap_used)]
fn home_with_project() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    (tmp, project)
}

/// The whole defect in one run: the refusal used to name no command, and
/// `--discard-edits`, the flag that reads like the override, never reached
/// it. Both exits are spelled now, and the one that honours the declaration
/// is a flag apply actually has.
#[test]
#[allow(clippy::unwrap_used)]
fn a_blocked_declaration_is_printed_with_both_exits_that_resolve_it() {
    let (tmp, _) = home_with_project();
    let home = tmp.path();
    let project = migrating_project(home);

    let planned = said(&kendex(home, &project, &["apply", "--plan"]));
    assert!(
        planned.contains("conflict: skill deploy for Claude Code"),
        "{planned}"
    );
    assert!(
        planned.contains("to keep those files: adopt skill deploy"),
        "the exit that keeps the files names the item it applies to: {planned}"
    );
    assert!(
        planned.contains("apply with --replace-unmanaged"),
        "the exit that installs what was asked for: {planned}"
    );
    assert!(
        planned.contains("nothing to do until you settle the conflicts above"),
        "and the verdict does not read as nothing you can do: {planned}"
    );

    // The flag that reads like the override still is not one: an
    // unchanged conflict, not a silent no-op dressed as a fix.
    let edits = said(&kendex(
        home,
        &project,
        &["apply", "--plan", "--discard-edits"],
    ));
    assert!(edits.contains("conflict: skill deploy"), "{edits}");

    let taken = kendex(home, &project, &["apply", "-y", "--replace-unmanaged"]);
    assert!(taken.status.success(), "{taken:?}");
    let printed = said(&taken);
    assert!(!printed.contains("conflict:"), "{printed}");
    assert!(
        printed.contains("Move the files already at"),
        "the plan says where the old files go: {printed}"
    );
    assert!(
        fs::read_to_string(project.join(".claude/skills/deploy/SKILL.md"))
            .unwrap()
            .contains("Upstream.")
    );
}

/// Listed by one command and invisible to the others is a thin line
/// between "safely ignored" and "silently unmanaged". Both commands that
/// report on a scope now say what they did not look at.
#[test]
#[allow(clippy::unwrap_used)]
fn content_nothing_declares_is_named_by_apply_and_by_verify() {
    let (tmp, project) = home_with_project();
    let home = tmp.path();
    migrating_project(home);
    fs::create_dir_all(project.join(".claude/skills/shadcn")).unwrap();
    fs::write(
        project.join(".claude/skills/shadcn/SKILL.md"),
        "---\nname: shadcn\ndescription: components\n---\nMine.\n",
    )
    .unwrap();

    let listed = String::from_utf8_lossy(&kendex(home, &project, &["list"]).stderr).into_owned();
    assert!(listed.contains("shadcn"), "{listed}");

    let planned = said(&kendex(home, &project, &["apply", "--plan"]));
    assert!(planned.contains("not managed:"), "{planned}");
    assert!(planned.contains("shadcn"), "{planned}");

    let verified = kendex(home, &project, &["verify"]);
    assert!(verified.status.success(), "unmanaged content is not drift");
    let printed = said(&verified);
    assert!(printed.contains("not managed:"), "{printed}");
    assert!(printed.contains("shadcn"), "{printed}");
    let row = planned
        .lines()
        .find(|line| line.contains("shadcn"))
        .unwrap_or_default();
    assert!(
        row.contains("Claude Code"),
        "a plan preview names the tool the way a person reads it: {row}"
    );
}

/// The footnote reads names and paths off a tree kendex did not write —
/// which is the whole point of it — so a folder named with an escape
/// sequence must print as its own characters and never act on the terminal.
#[test]
#[allow(clippy::unwrap_used)]
fn a_name_that_could_move_the_cursor_is_printed_as_text() {
    let (tmp, project) = home_with_project();
    let home = tmp.path();
    migrating_project(home);
    let hostile = project.join(".claude/skills/ev\u{1b}[31mil");
    fs::create_dir_all(&hostile).unwrap();
    fs::write(
        hostile.join("SKILL.md"),
        "---\nname: evil\ndescription: paints the terminal\n---\nMine.\n",
    )
    .unwrap();

    let planned = said(&kendex(home, &project, &["apply", "--plan"]));
    assert!(planned.contains("not managed:"), "{planned}");
    assert!(
        !planned.contains('\u{1b}'),
        "an escape sequence reached the terminal: {planned:?}"
    );
}

/// verify is the CI-facing gate: its exit code answers about drift and
/// nothing else. Gathering unmanaged rows made it plan scopes it used to
/// skip, and a scope whose manifest cannot be planned against — malformed
/// TOML here — turned a clean run into a failed build.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unplannable_scope_with_nothing_installed_does_not_fail_the_run() {
    let (tmp, project) = home_with_project();
    let home = tmp.path();
    migrating_project(home);
    assert!(
        kendex(home, &project, &["apply", "-y", "--replace-unmanaged"])
            .status
            .success()
    );

    // A global manifest this build cannot read, and nothing installed
    // globally to check against it.
    #[cfg(target_os = "macos")]
    let config = home.join("Library/Application Support/kendex");
    #[cfg(not(target_os = "macos"))]
    let config = home.join(".config/kendex");
    fs::create_dir_all(&config).unwrap();
    fs::write(config.join("kendex.toml"), "schema = 5\n[skills.\n").unwrap();

    let verified = kendex(home, &project, &["verify", "--scope", "all"]);
    let printed = said(&verified);
    assert!(
        printed.contains("1 checked, 1 OK, 0 failed"),
        "the summary still prints: {printed}"
    );
    assert!(printed.contains("not checked"), "and says why: {printed}");
    assert!(
        verified.status.success(),
        "nothing drifted, so nothing failed: {printed}"
    );
}

/// The footnote belongs to the two commands that report on a whole scope.
/// It rode inside the shared report printer for a while, which put an
/// inventory of hand-made content at the end of every add and every pin.
#[test]
#[allow(clippy::unwrap_used)]
fn only_the_commands_that_report_on_a_scope_name_unmanaged_content() {
    let (tmp, project) = home_with_project();
    let home = tmp.path();
    migrating_project(home);
    fs::create_dir_all(project.join(".claude/skills/shadcn")).unwrap();
    fs::write(
        project.join(".claude/skills/shadcn/SKILL.md"),
        "---\nname: shadcn\ndescription: components\n---\nMine.\n",
    )
    .unwrap();
    assert!(
        kendex(home, &project, &["apply", "-y", "--replace-unmanaged"])
            .status
            .success()
    );

    let pinned = said(&kendex(
        home,
        &project,
        &["pin", "skill", "deploy", "--follow", "-y"],
    ));
    assert!(
        !pinned.contains("not managed:"),
        "pin was not asked for an inventory: {pinned}"
    );
    assert!(
        said(&kendex(home, &project, &["apply", "--plan"])).contains("not managed:"),
        "and apply still names it"
    );
}

/// Adoption takes agents and skills; for anything else, naming it would
/// send the reader to a command that refuses. The pair stays symmetric —
/// the safe way out is always spelled, whether it is a verb or a move the
/// reader makes themselves.
#[test]
#[allow(clippy::unwrap_used)]
fn the_way_out_that_keeps_files_is_spelled_for_every_kind() {
    let (tmp, project) = home_with_project();
    let home = tmp.path();
    migrating_project(home);
    let catalog = home.join("catalog");
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::create_dir_all(catalog.join("commands")).unwrap();
    fs::write(
        catalog.join("commands/ship.md"),
        "---\ndescription: ships it\n---\nUpstream.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/commands")).unwrap();
    fs::write(
        project.join(".claude/commands/ship.md"),
        "the tool that came before",
    )
    .unwrap();
    let toml = fs::read_to_string(project.join("kendex.toml")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!("{toml}\n[commands.ship]\nsource = \"cat\"\n"),
    )
    .unwrap();

    let planned = said(&kendex(home, &project, &["apply", "--plan"]));
    assert!(
        planned.contains("to keep those files: adopt skill deploy"),
        "{planned}"
    );
    assert!(
        planned.contains("to keep those files: move them somewhere else first"),
        "adoption does not take a command, so the line says what does: {planned}"
    );
    assert!(
        !planned.contains("adopt command"),
        "and never names a command that would refuse: {planned}"
    );
}

/// A repo being moved onto kendex is exactly where the count is large. The
/// half that names an item belongs on that item's row; the half that names
/// the flag is the same for all of them and is said once.
#[test]
#[allow(clippy::unwrap_used)]
fn the_shared_way_out_is_said_once_however_many_items_are_blocked() {
    let (tmp, project) = home_with_project();
    let home = tmp.path();
    let catalog = home.join("catalog");
    let mut declarations = String::new();
    for name in ["deploy", "lint", "ship"] {
        fs::create_dir_all(catalog.join(format!("skills/{name}"))).unwrap();
        fs::write(
            catalog.join(format!("skills/{name}/SKILL.md")),
            format!("---\nname: {name}\ndescription: does {name}\n---\nUpstream.\n"),
        )
        .unwrap();
        let here = project.join(format!(".claude/skills/{name}"));
        fs::create_dir_all(&here).unwrap();
        fs::write(here.join("SKILL.md"), "the tool that came before").unwrap();
        declarations.push_str(&format!("\n[skills.{name}]\nsource = \"cat\"\n"));
    }
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n{declarations}",
            catalog.display()
        ),
    )
    .unwrap();

    let planned = said(&kendex(home, &project, &["apply", "--plan"]));
    assert_eq!(
        planned.matches("--replace-unmanaged").count(),
        1,
        "{planned}"
    );
    for name in ["deploy", "lint", "ship"] {
        assert!(
            planned.contains(&format!("to keep those files: adopt skill {name}")),
            "{planned}"
        );
    }
}

/// Adoption reads one tool's position, and left unsaid it reads Claude
/// Code's. A conflict on any other tool was directing the reader at a
/// place that is not the one blocked.
#[test]
#[allow(clippy::unwrap_used)]
fn the_way_out_names_the_tool_that_is_blocked() {
    let (tmp, project) = home_with_project();
    let home = tmp.path();
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nUpstream.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"opencode\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    fs::create_dir_all(project.join(".opencode/skills/deploy")).unwrap();
    fs::write(
        project.join(".opencode/skills/deploy/SKILL.md"),
        "the tool that came before",
    )
    .unwrap();

    let planned = said(&kendex(home, &project, &["apply", "--plan"]));
    assert!(
        planned.contains("to keep those files: adopt skill deploy --harness opencode"),
        "{planned}"
    );
}
