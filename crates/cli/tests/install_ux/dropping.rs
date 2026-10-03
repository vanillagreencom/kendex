//! Dropping a tool from a project's list: what kendex wrote for it goes,
//! the keys it wrote in that tool's settings included, and the folders
//! that leaves empty go with it. What the person put there stays.

use super::{World, git, read, write};

/// A project installing a skill for Claude Code and Gemini CLI, with the
/// root `AGENTS.md` Gemini's settings are pointed at. Gemini then leaves
/// the list: with nothing of the person's in `.gemini/`, the folder is
/// gone; with a setting of their own in its settings file, that setting
/// and the file stay and only kendex's entry leaves.
#[test]
#[allow(clippy::unwrap_used)]
fn dropping_a_tool_leaves_nothing_of_kendexs_behind() {
    struct Row {
        what: &'static str,
        theirs: Option<&'static str>,
    }
    for row in [
        Row {
            what: "nothing of the person's",
            theirs: None,
        },
        Row {
            what: "a setting of the person's",
            theirs: Some("{\n  \"ui\": {\n    \"theme\": \"Dark\"\n  }\n}\n"),
        },
    ] {
        let world = World::new(&["claude"]);
        write(&world.at("AGENTS.md"), "# app\n");
        if let Some(theirs) = row.theirs {
            write(&world.at(".gemini/settings.json"), theirs);
        }
        git(&world.project, &["add", "-A"]);
        git(&world.project, &["commit", "--quiet", "-m", "agents"]);
        let declare = |harnesses: &[&str]| {
            world.declare_no_items(harnesses);
            let manifest = world.manifest();
            write(
                &world.at("kendex.toml"),
                &format!("{manifest}\n[skills.deploy]\nsource = \"cat\"\n"),
            );
        };

        let what = row.what;
        declare(&["claude", "gemini"]);
        world.run(&["apply", "-y", "--leave"]);
        let settings = read(&world.at(".gemini/settings.json"));
        assert!(settings.contains("AGENTS.md"), "{what}: {settings}");

        declare(&["claude"]);
        let said = world.run(&["apply", "-y", "--leave"]);
        assert!(
            world.at(".agents/skills/deploy/SKILL.md").exists(),
            "{what}"
        );
        match row.theirs {
            None => assert!(!world.at(".gemini").exists(), "{what}:\n{said}"),
            Some(theirs) => {
                let left: serde_json::Value =
                    serde_json::from_str(&read(&world.at(".gemini/settings.json"))).unwrap();
                let theirs: serde_json::Value = serde_json::from_str(theirs).unwrap();
                assert_eq!(left, theirs, "{what}:\n{said}");
            }
        }
    }
}
