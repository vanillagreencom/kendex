//! `kendex verify` and a declared hook's `harnesses` pin: each tool the
//! pin decides against the hook's own reading is a `notice` row naming the
//! hook and the tool, which leaves the run clean under `--strict`. A pin
//! that decides nothing the hook would not decide itself prints none.
//!
//! Controls, each a row the named defect turns red:
//! - the leave-out row: the engine no longer recording a tool its pin alone
//!   keeps the hook off (`desired_kinds::pin_leaves_out`) empties the
//!   Claude-only row's notices;
//! - the excluded-tool row: the engine no longer recording a pin naming a
//!   tool the hook's own line leaves out empties that row's notices;
//! - a left-out tool the hook's own line excludes as well: recording every
//!   tool a pin leaves out, whatever the hook says, puts a notice on the
//!   row whose pin matches its line.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;

use kendex_core::attest::{Document, State};
use kendex_core::model::HarnessId;

use super::verify_records::{kendex, said, write};

const HOOK: &str = "guard";
const EVERY_TOOL: &str = "";
const CLAUDE_ONLY: &str = "# harnesses: [claude]\n";

/// One consumer: the hook's own harnesses line, the pin on its
/// declaration, and what apply and verify make of them.
struct Case {
    /// The `harnesses:` header line, or none for every tool.
    header: &'static str,
    /// The declaration's `harnesses` value, or `None` for no pin.
    pin: Option<&'static str>,
    /// The tools apply records the hook for.
    recorded: &'static [HarnessId],
    /// The tools verify names in a notice row for the hook.
    noticed: &'static [HarnessId],
}

const CASES: &[Case] = &[
    Case {
        header: EVERY_TOOL,
        pin: Some("[\"claude\"]"),
        recorded: &[HarnessId::Claude],
        noticed: &[HarnessId::Copilot],
    },
    Case {
        header: EVERY_TOOL,
        pin: None,
        recorded: &[HarnessId::Claude, HarnessId::Copilot],
        noticed: &[],
    },
    Case {
        header: EVERY_TOOL,
        pin: Some("[\"claude\", \"copilot\"]"),
        recorded: &[HarnessId::Claude, HarnessId::Copilot],
        noticed: &[],
    },
    Case {
        header: CLAUDE_ONLY,
        pin: Some("[\"claude\", \"copilot\"]"),
        recorded: &[HarnessId::Claude],
        noticed: &[HarnessId::Copilot],
    },
    Case {
        header: CLAUDE_ONLY,
        pin: Some("[\"claude\"]"),
        recorded: &[HarnessId::Claude],
        noticed: &[],
    },
];

#[test]
fn verify_names_each_tool_a_hook_pin_decides_and_stays_clean_under_strict() {
    for case in CASES {
        check(case);
    }
}

#[allow(clippy::unwrap_used)]
fn check(case: &Case) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    let project = home.join("consumer");
    write(&catalog.join("kendex.toml"), "is_source_catalog = true\n");
    write(
        &catalog.join(format!("hooks/{HOOK}.sh")),
        &format!(
            "#!/usr/bin/env bash\n# ---\n# name: {HOOK}\n# event: PreToolUse\n# matcher: Bash\n# description: guards\n{}# ---\nexit 0\n",
            case.header
        ),
    );
    let pin = case
        .pin
        .map(|list| format!("harnesses = {list}\n"))
        .unwrap_or_default();
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\", \"copilot\"]\nmethod = \"copy\"\n[hooks.{HOOK}]\nsource = \"cat\"\n{pin}",
            source_path(&catalog),
        ),
    );
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(project.join(".github")).unwrap();
    let at = format!("header {:?} pin {:?}", case.header, case.pin);
    let applied = kendex(&home, &project, &["apply", "-y", "--leave"]);
    assert!(applied.status.success(), "{at}: {}", said(&applied));
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    let recorded: Vec<HarnessId> = [HarnessId::Claude, HarnessId::Copilot]
        .into_iter()
        .filter(|harness| {
            lock["entries"]
                .as_object()
                .unwrap()
                .contains_key(&format!("hook:{HOOK}:{}", harness.name()))
        })
        .collect();
    assert_eq!(recorded, case.recorded, "{at}: {lock}");

    let verified = kendex(
        &home,
        &project,
        &["verify", "--scope", "project", "--strict", "--json"],
    );
    let printed = said(&verified);
    assert!(verified.status.success(), "{at}: {printed}");
    let document: Document = serde_json::from_slice(&verified.stdout)
        .unwrap_or_else(|error| panic!("{at}: verify document: {error}\n{printed}"));
    let noticed: Vec<(&str, &str, Option<HarnessId>)> = document
        .rows
        .iter()
        .filter(|row| row.state == State::Notice)
        .map(|row| (row.kind.as_str(), row.name.as_str(), row.harness))
        .collect();
    let expected: Vec<(&str, &str, Option<HarnessId>)> = case
        .noticed
        .iter()
        .map(|harness| ("hook", HOOK, Some(*harness)))
        .collect();
    assert_eq!(noticed, expected, "{at}: {printed}");
}
