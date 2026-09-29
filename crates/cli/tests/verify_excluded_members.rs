//! `kendex verify` and a bundle member whose own harnesses line names no
//! tool the consumer installs on: apply writes it nowhere and records
//! nothing for it, so verify passes it over and says so on one line. With
//! the tool configured the member installs, and a record that lost its
//! entry still fails as a declaration the record does not hold.
//!
//! The must-fail control for the pass-over is the verify before it, which
//! counted the member as listed and not in the install record and closed
//! the first row non-zero. The control for the rule that every planned
//! tool must be left out, not any one, is the second row: a member
//! installed on Claude and left off Codex passed over there prints the
//! pass-over line.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;

use super::verify_records::{kendex, said, write};

/// The one line a scope prints for the members it passed over.
const PASSED_OVER: &str = "1 package installs on no tool here, its own harnesses line names none of them: hook claude-only";

/// The headline a declaration with no record entry prints.
const GAP: &str = "1 package listed and not in the install record";

#[test]
#[allow(clippy::unwrap_used)]
fn a_member_for_no_configured_tool_is_passed_over_and_one_that_installs_is_held_to_the_record() {
    // (tools the consumer installs on, drop the member's record entry,
    // verify passes, the pass-over line printed, the gap line printed)
    let rows: [(&str, bool, bool, bool, bool); 3] = [
        ("[\"codex\"]", false, true, true, false),
        ("[\"claude\", \"codex\"]", false, true, false, false),
        ("[\"claude\", \"codex\"]", true, false, false, true),
    ];
    for (tools, drop_entry, passes, passed_over, gap) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let catalog = home.join("catalog");
        let project = home.join("consumer");
        write(
            &catalog.join("kendex.toml"),
            "is_source_catalog = true\n\n[bundles.workflow]\ndescription = \"the workflow set\"\nskills = [\"tidy\"]\nhooks = [\"claude-only\"]\n",
        );
        write(
            &catalog.join("skills/tidy/SKILL.md"),
            "---\nname: tidy\ndescription: tidies\n---\nTidy.\n",
        );
        write(
            &catalog.join("hooks/claude-only.sh"),
            "#!/usr/bin/env bash\n# ---\n# name: claude-only\n# event: PreToolUse\n# matcher: Bash\n# description: runs on Claude alone\n# harnesses: [claude]\n# ---\nexit 0\n",
        );
        write(
            &project.join("kendex.toml"),
            &format!(
                "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = {tools}\nmethod = \"copy\"\n[bundles.workflow]\nsource = \"cat\"\n",
                source_path(&catalog)
            ),
        );
        fs::create_dir_all(project.join(".claude")).unwrap();
        let applied = kendex(&home, &project, &["apply", "-y", "--leave"]);
        assert!(applied.status.success(), "{tools}: {}", said(&applied));
        let record = project.join(".kendex-lock.json");
        let mut lock: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&record).unwrap()).unwrap();
        let entries = lock["entries"].as_object_mut().unwrap();
        assert_eq!(
            entries.contains_key("hook:claude-only:claude"),
            !passed_over,
            "{tools}: {lock}"
        );
        if drop_entry {
            entries.remove("hook:claude-only:claude").unwrap();
            fs::write(&record, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
        }
        let verified = kendex(&home, &project, &["verify", "--scope", "project"]);
        let printed = said(&verified);
        assert_eq!(verified.status.success(), passes, "{tools}: {printed}");
        assert_eq!(
            printed.contains(PASSED_OVER),
            passed_over,
            "{tools}: {printed}"
        );
        assert_eq!(printed.contains(GAP), gap, "{tools}: {printed}");
        assert_eq!(
            printed.contains("hook claude-only — kendex apply records it"),
            gap,
            "{tools}: {printed}"
        );
    }
}
