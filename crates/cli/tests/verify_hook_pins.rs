//! `kendex verify` and a declared hook's `harnesses` pin: each tool the
//! pin decides against the hook's own reading is a `notice` row naming the
//! hook and the tool, which leaves the run clean under `--strict`. A pin
//! that decides nothing the hook would not decide itself prints none. The
//! engine's record of what the pin does on each tool, which picks the
//! remedy verify prints, is checked beside the rows.
//!
//! Controls, each a row the named defect turns red:
//! - the leave-out row: the engine no longer recording a tool its pin alone
//!   keeps the hook off (`desired_kinds::pins_left_out`) empties the
//!   Claude-only row's notices;
//! - the excluded-tool row: recording `Pin::LeavesOut` in
//!   `desired_kinds::pin_names_excluded` reddens that row's pin;
//! - a left-out tool the hook's own line excludes as well: recording every
//!   tool a pin leaves out, whatever the hook says, puts a notice on the
//!   row whose pin matches its line;
//! - the bundled row, where a set carries the pinned hook onto a tool its
//!   pin leaves out and onto one `[install]` leaves out: asking
//!   `pins_left_out` only the tools the scope installs on loses the Codex
//!   record, and asking a tool twice repeats the Copilot one;
//! - the same row's run naming the set: dropping the names filter in
//!   `verify::pinned_hook_rows` prints the pinned hook's notices.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;

use kendex_core::attest::{Document, State};
use kendex_core::engine::{Pin, PinnedHook};
use kendex_core::env::Env;
use kendex_core::model::{HarnessId, Scope};

use super::verify_records::{kendex, said, write};

const HOOK: &str = "guard";
/// A catalog set carrying [`HOOK`], installed on both `[install]` tools and
/// on Codex, which `[install]` leaves out.
const BUNDLE: &str = "starter";
const EVERY_TOOL: &str = "";
const CLAUDE_ONLY: &str = "# harnesses: [claude]\n";

/// One consumer: the hook's own harnesses line, the pin on its
/// declaration, and what apply and verify make of them.
struct Case {
    /// The `harnesses:` header line, or none for every tool.
    header: &'static str,
    /// The declaration's `harnesses` value, or `None` for no pin.
    pin: Option<&'static str>,
    /// Whether [`BUNDLE`] is declared beside the hook.
    bundled: bool,
    /// The tools apply records the hook for.
    recorded: &'static [HarnessId],
    /// What the engine records the pin doing, tool by tool; verify names
    /// each tool in a notice row for the hook.
    pinned: &'static [(HarnessId, Pin)],
}

const CASES: &[Case] = &[
    Case {
        header: EVERY_TOOL,
        pin: Some("[\"claude\"]"),
        bundled: false,
        recorded: &[HarnessId::Claude],
        pinned: &[(HarnessId::Copilot, Pin::LeavesOut)],
    },
    Case {
        header: EVERY_TOOL,
        pin: None,
        bundled: false,
        recorded: &[HarnessId::Claude, HarnessId::Copilot],
        pinned: &[],
    },
    Case {
        header: EVERY_TOOL,
        pin: Some("[\"claude\", \"copilot\"]"),
        bundled: false,
        recorded: &[HarnessId::Claude, HarnessId::Copilot],
        pinned: &[],
    },
    Case {
        header: CLAUDE_ONLY,
        pin: Some("[\"claude\", \"copilot\"]"),
        bundled: false,
        recorded: &[HarnessId::Claude],
        pinned: &[(HarnessId::Copilot, Pin::NamesExcluded)],
    },
    Case {
        header: CLAUDE_ONLY,
        pin: Some("[\"claude\"]"),
        bundled: false,
        recorded: &[HarnessId::Claude],
        pinned: &[],
    },
    Case {
        header: EVERY_TOOL,
        pin: Some("[\"claude\"]"),
        bundled: true,
        recorded: &[HarnessId::Claude],
        pinned: &[
            (HarnessId::Copilot, Pin::LeavesOut),
            (HarnessId::Codex, Pin::LeavesOut),
        ],
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
    let (catalog_sets, bundle) = match case.bundled {
        true => (
            format!("[bundles.{BUNDLE}]\nhooks = [\"{HOOK}\"]\n"),
            format!(
                "[bundles.{BUNDLE}]\nsource = \"cat\"\nharnesses = [\"claude\", \"copilot\", \"codex\"]\n"
            ),
        ),
        false => (String::new(), String::new()),
    };
    write(
        &catalog.join("kendex.toml"),
        &format!("is_source_catalog = true\n{catalog_sets}"),
    );
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
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\", \"copilot\"]\nmethod = \"copy\"\n{bundle}[hooks.{HOOK}]\nsource = \"cat\"\n{pin}",
            source_path(&catalog),
        ),
    );
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(project.join(".github")).unwrap();
    let at = format!(
        "header {:?} pin {:?} bundled {}",
        case.header, case.pin, case.bundled
    );
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
    let report = kendex_core::engine::audit(
        &Env::host_rooted(&home),
        &Scope::Project {
            root: project.clone(),
        },
    )
    .unwrap();
    let pinned: Vec<PinnedHook> = case
        .pinned
        .iter()
        .map(|&(harness, pin)| PinnedHook {
            name: HOOK.to_owned(),
            harness,
            pin,
        })
        .collect();
    assert_eq!(report.pinned_hooks, pinned, "{at}");

    let verified = kendex(
        &home,
        &project,
        &["verify", "--scope", "project", "--strict", "--json"],
    );
    let printed = said(&verified);
    assert!(verified.status.success(), "{at}: {printed}");
    let document: Document = serde_json::from_slice(&verified.stdout)
        .unwrap_or_else(|error| panic!("{at}: verify document: {error}\n{printed}"));
    let expected: Vec<(&str, &str, Option<HarnessId>)> = case
        .pinned
        .iter()
        .map(|&(harness, _)| ("hook", HOOK, Some(harness)))
        .collect();
    assert_eq!(notices(&document), expected, "{at}: {printed}");

    if case.bundled {
        let narrowed = kendex(
            &home,
            &project,
            &["verify", BUNDLE, "--scope", "project", "--strict", "--json"],
        );
        let printed = said(&narrowed);
        assert!(narrowed.status.success(), "{at}: {printed}");
        let document: Document = serde_json::from_slice(&narrowed.stdout)
            .unwrap_or_else(|error| panic!("{at}: narrowed verify document: {error}\n{printed}"));
        assert_eq!(notices(&document), [], "{at}: {printed}");
    }
}

fn notices(document: &Document) -> Vec<(&str, &str, Option<HarnessId>)> {
    document
        .rows
        .iter()
        .filter(|row| row.state == State::Notice)
        .map(|row| (row.kind.as_str(), row.name.as_str(), row.harness))
        .collect()
}
