//! Dropping a tool from a project's list: what kendex wrote for it goes,
//! the keys it wrote in that tool's settings included, and the folders
//! that leaves empty go with it. What the person put there stays.

use super::{World, git, read, write};

/// A project installing a skill for Claude Code and Gemini CLI, with the
/// root `AGENTS.md` both shims point at. One tool then leaves the list.
/// Gemini leaving with nothing of the person's in `.gemini/` takes the
/// folder; with a setting of their own in its settings file, that setting
/// and the file stay and only kendex's entry leaves. Claude Code leaving
/// takes the `CLAUDE.md` shim kendex wrote, and leaves one the person
/// wrote. A pass after that finds nothing left to do about either.
#[test]
#[allow(clippy::unwrap_used)]
fn dropping_a_tool_leaves_nothing_of_kendexs_behind() {
    const GEMINI: &str = ".gemini/settings.json";
    struct Row {
        what: &'static str,
        dropped: &'static str,
        /// A file of the person's, written and committed before the first
        /// apply, and what it holds.
        theirs: Option<(&'static str, &'static str)>,
    }
    for row in [
        Row {
            what: "Gemini, nothing of the person's",
            dropped: "gemini",
            theirs: None,
        },
        Row {
            what: "Gemini, a setting of the person's",
            dropped: "gemini",
            theirs: Some((GEMINI, "{\n  \"ui\": {\n    \"theme\": \"Dark\"\n  }\n}\n")),
        },
        Row {
            what: "Claude Code, the shim kendex wrote",
            dropped: "claude",
            theirs: None,
        },
        Row {
            what: "Claude Code, a CLAUDE.md the person wrote",
            dropped: "claude",
            theirs: Some(("CLAUDE.md", "# mine\n@AGENTS.md\n")),
        },
    ] {
        let world = World::new(&["claude"]);
        write(&world.at("AGENTS.md"), "# app\n");
        if let Some((path, theirs)) = row.theirs {
            write(&world.at(path), theirs);
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
        let settings = read(&world.at(GEMINI));
        assert!(settings.contains("AGENTS.md"), "{what}: {settings}");

        let kept: Vec<&str> = ["claude", "gemini"]
            .into_iter()
            .filter(|harness| *harness != row.dropped)
            .collect();
        declare(&kept);
        let said = world.run(&["apply", "-y", "--leave"]);
        assert!(
            world.at(".agents/skills/deploy/SKILL.md").exists(),
            "{what}"
        );
        match (row.dropped, row.theirs) {
            ("gemini", None) => assert!(!world.at(".gemini").exists(), "{what}:\n{said}"),
            ("claude", None) => assert!(!world.at("CLAUDE.md").exists(), "{what}:\n{said}"),
            (_, Some((path, theirs))) if path == GEMINI => {
                let left: serde_json::Value =
                    serde_json::from_str(&read(&world.at(GEMINI))).unwrap();
                let theirs: serde_json::Value = serde_json::from_str(theirs).unwrap();
                assert_eq!(left, theirs, "{what}:\n{said}");
            }
            (_, Some((path, theirs))) => assert_eq!(read(&world.at(path)), theirs, "{what}"),
            (dropped, None) => unreachable!("no row drops {dropped}"),
        }

        // Settled: the next pass names neither file and writes nothing,
        // and a verify finds nothing left over of the dropped tool's.
        let again = world.run(&["apply", "-y", "--leave"]);
        for named in [GEMINI, "CLAUDE.md"] {
            assert!(
                !again.contains(named),
                "{what}: {named} named again:\n{again}"
            );
        }
        assert!(
            again.contains("nothing to do"),
            "{what}: a pass planned:\n{again}"
        );
        let verified = world.try_run(&["verify"]);
        let checked = super::said(&verified);
        assert!(verified.status.success(), "{what}:\n{checked}");
        let gone = match row.dropped {
            "gemini" => GEMINI,
            _ => "CLAUDE.md",
        };
        assert!(!checked.contains(gone), "{what}:\n{checked}");
    }
}
