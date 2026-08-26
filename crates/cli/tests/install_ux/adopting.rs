//! Taking over what somebody already had: a skill sitting in a tool's own
//! directory, and a hook they registered by hand.

use crate::{World, link_text, read, said};

const HAND_MADE: &str =
    "---\nname: release\ndescription: cut a release\n---\nThe way we have always done it.\n";

/// The natural path a person actually has their skill at. Adoption moves
/// the real directory into the shared home and leaves a link behind, so
/// the tool that had it keeps reading the same path.
#[test]
fn adopting_a_claude_skill_moves_it_into_the_shared_home() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    crate::write(&world.at(".claude/skills/release/SKILL.md"), HAND_MADE);
    crate::write(&world.at(".claude/skills/release/notes.md"), "Notes.\n");

    world.run(&["adopt", "skill", "release"]);

    let shared = world.at(".agents/skills/release");
    assert!(shared.is_dir() && !shared.is_symlink());
    assert!(read(&shared.join("SKILL.md")).contains("always done it"));
    assert!(read(&shared.join("notes.md")).contains("Notes."));

    let natural = world.at(".claude/skills/release");
    assert_eq!(link_text(&natural), "../../.agents/skills/release");
    assert!(read(&natural.join("SKILL.md")).contains("always done it"));

    // No hidden capture directory: the shared tree is the content itself.
    assert!(!world.at(".kendex-local/skills/release").exists());
    assert!(
        world.manifest().contains("[skills.release]"),
        "{}",
        world.manifest()
    );
}

/// Once adopted, refresh keeps the structure and the links without
/// rewriting the content the person owns.
#[test]
fn refresh_maintains_an_adopted_skill_without_touching_its_content() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    crate::write(&world.at(".claude/skills/release/SKILL.md"), HAND_MADE);
    world.run(&["adopt", "skill", "release"]);

    let shared = world.at(".agents/skills/release/SKILL.md");
    crate::write(&shared, &HAND_MADE.replace("always", "usually"));
    world.run(&["refresh", "-y"]);
    assert!(
        read(&shared).contains("usually"),
        "refresh overwrote the content"
    );
    assert!(world.at(".claude/skills/release").is_symlink());
    assert!(world.try_run(&["verify"]).status.success());
}

/// An adopted skill is committed like an installed one, so the teammate who
/// clones gets it too.
#[test]
#[allow(clippy::unwrap_used)]
fn an_adopted_skill_clones() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    crate::write(&world.at(".claude/skills/release/SKILL.md"), HAND_MADE);
    world.run(&["adopt", "skill", "release"]);
    world.commit_all("adopt release");

    let clone = world.tmp.path().join("elsewhere/adopted");
    std::fs::create_dir_all(clone.parent().unwrap()).unwrap();
    crate::git(
        &world.project,
        &["clone", "--quiet", ".", &clone.display().to_string()],
    );
    assert!(read(&clone.join(".claude/skills/release/SKILL.md")).contains("always done it"));
}

/// A hook the person registered themselves: the script moves to the
/// canonical home, kendex's registration replaces theirs, and the other
/// entries in the same file are untouched.
#[test]
fn adopting_a_hook_rewrites_only_its_own_registration() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    crate::write(
        &world.at(".claude/settings.json"),
        r#"{
  "env": {"KEEP": "1"},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": ".claude/hooks/guard.sh"}]},
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "./other-tool.sh"}]}
    ]
  }
}
"#,
    );
    crate::write(
        &world.at(".claude/hooks/guard.sh"),
        "#!/bin/sh\necho guard\n",
    );

    let listed = said(&world.try_run(&["verify"]));
    assert!(
        listed.contains("guard"),
        "the hook was never offered:\n{listed}"
    );

    world.run(&["adopt", "hook", "PreToolUse:Bash:guard"]);

    let manifest = world.manifest();
    assert!(manifest.contains("[[custom-hooks]]"), "{manifest}");
    assert!(manifest.contains("PreToolUse"), "{manifest}");

    let settings = read(&world.at(".claude/settings.json"));
    assert!(settings.contains("./other-tool.sh"), "{settings}");
    assert!(settings.contains("KEEP"), "{settings}");
    assert!(settings.contains("guard"), "{settings}");
    assert!(world.at(".agents/hooks/guard.sh").is_file());
}

/// A command that runs something from outside the project is left exactly
/// as it was: moving it would drag a file the project does not own into the
/// tree the project commits.
#[test]
fn a_hook_running_a_script_outside_the_project_keeps_its_command() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    crate::write(&world.home.join("outside.sh"), "#!/bin/sh\nexit 0\n");
    crate::write(
        &world.at(".claude/settings.json"),
        r#"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "../../outside.sh"}]}]}}"#,
    );

    world.run(&["adopt", "hook", "PreToolUse:Bash:outside"]);

    let manifest = world.manifest();
    assert!(manifest.contains("../../outside.sh"), "{manifest}");
    assert!(!world.at(".agents/hooks").exists());
    assert!(world.home.join("outside.sh").is_file());
}

/// An entry doing something a declaration has no field for would come back
/// as a plain command hook, running differently with nothing said.
#[test]
fn a_hook_a_declaration_cannot_express_is_refused() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    crate::write(
        &world.at(".claude/settings.json"),
        r#"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": ".claude/hooks/guard.sh", "env": {"TOKEN": "x"}}]}]}}"#,
    );
    crate::write(&world.at(".claude/hooks/guard.sh"), "#!/bin/sh\nexit 0\n");

    let refused = world.try_run(&["adopt", "hook", "PreToolUse:Bash:guard"]);
    assert!(!refused.status.success());
    let text = said(&refused);
    assert!(text.contains("env"), "{text}");
    assert!(world.at(".claude/hooks/guard.sh").is_file());
}

/// A timeout is part of what the hook does, so it travels with it.
#[test]
fn an_adopted_hook_keeps_its_timeout() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    crate::write(
        &world.at(".claude/settings.json"),
        r#"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": ".claude/hooks/guard.sh", "timeout": 45}]}]}}"#,
    );
    crate::write(&world.at(".claude/hooks/guard.sh"), "#!/bin/sh\nexit 0\n");

    world.run(&["adopt", "hook", "PreToolUse:Bash:guard"]);
    assert!(
        world.manifest().contains("timeout = 45"),
        "{}",
        world.manifest()
    );
}

/// Copilot keeps its hooks in whichever document under `.github/hooks` their
/// author put them in, under its own event spelling. Adoption reads the file
/// the row came from, and the declaration says the event kendex declares
/// hooks against.
#[test]
fn a_copilot_hook_is_found_in_its_own_document_and_named_in_fleet_words() {
    let world = World::new(&["copilot"]);
    world.declare_catalog();
    crate::write(
        &world.at(".github/hooks/mine.json"),
        r#"{"version": 1, "hooks": {"preToolUse": [{"type": "command", "command": ".github/hooks/guard.sh", "matcher": "shell"}]}}"#,
    );
    crate::write(&world.at(".github/hooks/guard.sh"), "#!/bin/sh\nexit 0\n");

    world.run(&[
        "adopt",
        "hook",
        "preToolUse:shell:guard",
        "--harness",
        "copilot",
    ]);

    let manifest = world.manifest();
    assert!(manifest.contains("event = \"PreToolUse\""), "{manifest}");
    assert!(world.at(".agents/hooks/guard.sh").is_file());
}

/// Registering a project says what it found rather than waiting to be
/// asked, so nothing has to be discovered by browsing.
#[test]
fn registering_a_project_reports_what_it_could_manage() {
    let world = World::new(&["claude"]);
    crate::write(&world.at(".claude/skills/release/SKILL.md"), HAND_MADE);
    let said = crate::run(
        &world.home,
        &world.project,
        &["project", "add", &world.project.display().to_string()],
    );
    assert!(said.contains("release"), "{said}");
    // Runnable as printed: the tool the row is about, and the project it is
    // in — `adopt` acts on the current project and defaults to Claude Code.
    assert!(said.contains("--harness claude"), "{said}");
    assert!(
        said.contains(&world.project.display().to_string()),
        "{said}"
    );
}
