//! `kendex verify` and a hook's `harnesses` pin, on a `[hooks.<n>]`
//! declaration or a `[[custom-hooks]]` entry: each tool the pin decides
//! against the hook's own reading is a `notice` row naming the hook and the
//! tool, which leaves the run clean under `--strict`, whether the hook is
//! switched on or off. A pin that decides nothing the hook would not decide
//! itself prints none, and so does one leaving out a tool where a companion
//! the hook requires could not run beside it. The engine's record of what
//! the pin does on each tool, which picks the remedy verify prints, is
//! checked beside the rows, and each notice row's `state` is read as the
//! JSON spells it.
//!
//! Controls, each a row the named defect turns red:
//! - the leave-out row: the engine no longer recording a tool its pin alone
//!   keeps the hook off (`desired_kinds::pin_records`) empties the
//!   Claude-only row's notices;
//! - the excluded-tool row: recording `Pin::LeavesOut` for a tool the
//!   pin names and the header excludes reddens that row's pin;
//! - a left-out tool the hook's own line excludes as well: recording every
//!   tool a pin leaves out, whatever the hook says, puts a notice on the
//!   row whose pin matches its line;
//! - the bundled row, where a set carries the pinned hook onto a tool its
//!   pin leaves out and onto one `[install]` leaves out: asking
//!   `pin_records` only the tools the scope installs on loses the Codex
//!   record, and asking a tool twice repeats the Copilot one;
//! - the same row's run naming the set: dropping the names filter in
//!   `verify::pinned_hook_rows` prints the pinned hook's notices;
//! - the switched-off rows: asking `pin_records` through `not_written`,
//!   whose switched-off answer comes first, empties their notices;
//! - the companion row: `past_pin` no longer reading
//!   `DesiredState::withheld_past_pin` puts a notice on the requiring hook
//!   for the tool its companion's pin leaves out;
//! - the custom-hook rows: dropping the `pins_left_out` call in
//!   `desired_custom_hooks` empties the Claude-only entry's notices;
//! - every row with a notice: renaming `State::Notice`, or its wire
//!   spelling, empties the notices read off the JSON.
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
/// A hook [`HOOK`] requires where a case says so.
const COMPANION: &str = "judge";
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
    /// Whether the hook's declaration says `enabled = false`.
    switched_off: bool,
    /// The `harnesses` pin on a declaration of [`COMPANION`], which the
    /// hook then requires, or `None` for no companion.
    companion: Option<&'static str>,
    /// The tools apply records the hook for.
    recorded: &'static [HarnessId],
    /// What the engine records each hook's pin doing, tool by tool; verify
    /// names each in a notice row.
    pinned: &'static [(&'static str, HarnessId, Pin)],
}

const PLAIN: Case = Case {
    header: EVERY_TOOL,
    pin: None,
    bundled: false,
    switched_off: false,
    companion: None,
    recorded: &[],
    pinned: &[],
};

const CASES: &[Case] = &[
    Case {
        pin: Some("[\"claude\"]"),
        recorded: &[HarnessId::Claude],
        pinned: &[(HOOK, HarnessId::Copilot, Pin::LeavesOut)],
        ..PLAIN
    },
    Case {
        recorded: &[HarnessId::Claude, HarnessId::Copilot],
        ..PLAIN
    },
    Case {
        pin: Some("[\"claude\", \"copilot\"]"),
        recorded: &[HarnessId::Claude, HarnessId::Copilot],
        ..PLAIN
    },
    Case {
        header: CLAUDE_ONLY,
        pin: Some("[\"claude\", \"copilot\"]"),
        recorded: &[HarnessId::Claude],
        pinned: &[(HOOK, HarnessId::Copilot, Pin::NamesExcluded)],
        ..PLAIN
    },
    Case {
        header: CLAUDE_ONLY,
        pin: Some("[\"claude\"]"),
        recorded: &[HarnessId::Claude],
        ..PLAIN
    },
    Case {
        pin: Some("[\"claude\"]"),
        bundled: true,
        recorded: &[HarnessId::Claude],
        pinned: &[
            (HOOK, HarnessId::Copilot, Pin::LeavesOut),
            (HOOK, HarnessId::Codex, Pin::LeavesOut),
        ],
        ..PLAIN
    },
    Case {
        pin: Some("[\"claude\"]"),
        switched_off: true,
        recorded: &[HarnessId::Claude],
        pinned: &[(HOOK, HarnessId::Copilot, Pin::LeavesOut)],
        ..PLAIN
    },
    Case {
        header: CLAUDE_ONLY,
        pin: Some("[\"claude\", \"copilot\"]"),
        switched_off: true,
        recorded: &[HarnessId::Claude, HarnessId::Copilot],
        pinned: &[(HOOK, HarnessId::Copilot, Pin::NamesExcluded)],
        ..PLAIN
    },
    // With the pin dropped the hook would be withheld from Copilot, where
    // its companion's own pin keeps the companion off: the hook's pin
    // decides nothing there, and the companion's pin is the one said.
    Case {
        pin: Some("[\"claude\"]"),
        companion: Some("[\"claude\"]"),
        recorded: &[HarnessId::Claude],
        pinned: &[(COMPANION, HarnessId::Copilot, Pin::LeavesOut)],
        ..PLAIN
    },
    // A companion that runs everywhere stands in the way of nothing.
    Case {
        pin: Some("[\"claude\"]"),
        companion: Some("[\"claude\", \"copilot\"]"),
        recorded: &[HarnessId::Claude],
        pinned: &[(HOOK, HarnessId::Copilot, Pin::LeavesOut)],
        ..PLAIN
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
    lay_out(case, &catalog, &project);
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(project.join(".github")).unwrap();
    let at = format!(
        "header {:?} pin {:?} bundled {} off {} companion {:?}",
        case.header, case.pin, case.bundled, case.switched_off, case.companion
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
        .map(|&(name, harness, pin)| PinnedHook {
            name: name.to_owned(),
            harness,
            pin,
        })
        .collect();
    assert_eq!(report.pinned_hooks, pinned, "{at}");
    verified_notices(&home, &project, case.pinned, &at);

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

/// The catalog and the consumer manifest one case describes.
fn lay_out(case: &Case, catalog: &std::path::Path, project: &std::path::Path) {
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
    let requires = match case.companion {
        Some(_) => format!("# requires: [{COMPANION}]\n"),
        None => String::new(),
    };
    write(
        &catalog.join(format!("hooks/{HOOK}.sh")),
        &format!(
            "#!/usr/bin/env bash\n# ---\n# name: {HOOK}\n# event: PreToolUse\n# matcher: Bash\n# description: guards\n{}{requires}# ---\nexit 0\n",
            case.header
        ),
    );
    write(
        &catalog.join(format!("hooks/{COMPANION}.sh")),
        &format!(
            "#!/usr/bin/env bash\n# ---\n# name: {COMPANION}\n# event: Stop\n# description: judges\n# ---\nexit 0\n"
        ),
    );
    let pin = case
        .pin
        .map(|list| format!("harnesses = {list}\n"))
        .unwrap_or_default();
    let switch = match case.switched_off {
        true => "enabled = false\n",
        false => "",
    };
    let companion = case
        .companion
        .map(|list| format!("[hooks.{COMPANION}]\nsource = \"cat\"\nharnesses = {list}\n"))
        .unwrap_or_default();
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\", \"copilot\"]\nmethod = \"copy\"\n{bundle}{companion}[hooks.{HOOK}]\nsource = \"cat\"\n{pin}{switch}",
            source_path(catalog),
        ),
    );
}

/// What one `[[custom-hooks]]` entry's list does: the list, whether the
/// entry is switched off, and the tools verify names in a notice row.
const CUSTOM: &[(Option<&str>, bool, &[HarnessId])] = &[
    (Some("[\"claude\"]"), false, &[HarnessId::Copilot]),
    (Some("[\"claude\"]"), true, &[HarnessId::Copilot]),
    (None, false, &[]),
    (Some("[\"claude\", \"copilot\"]"), false, &[]),
];

#[test]
#[allow(clippy::unwrap_used)]
fn a_custom_hook_list_is_judged_as_a_hook_pin_is() {
    for &(list, switched_off, named) in CUSTOM {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = home.join("consumer");
        let list = list
            .map(|list| format!("harnesses = {list}\n"))
            .unwrap_or_default();
        let switch = match switched_off {
            true => "enabled = false\n",
            false => "",
        };
        write(
            &project.join("kendex.toml"),
            &format!(
                "schema = 6\n[install]\nharnesses = [\"claude\", \"copilot\"]\nmethod = \"copy\"\n\n[[custom-hooks]]\nname = \"{HOOK}\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./guard.sh\"\n{list}{switch}"
            ),
        );
        fs::create_dir_all(project.join(".claude")).unwrap();
        fs::create_dir_all(project.join(".github")).unwrap();
        let at = format!("list {list:?} off {switched_off}");
        let applied = kendex(&home, &project, &["apply", "-y", "--leave"]);
        assert!(applied.status.success(), "{at}: {}", said(&applied));
        let pinned: Vec<(&str, HarnessId, Pin)> = named
            .iter()
            .map(|&harness| (HOOK, harness, Pin::LeavesOut))
            .collect();
        verified_notices(&home, &project, &pinned, &at);
    }
}

/// Runs a strict verify over the project and checks its notice rows name
/// exactly `pinned`'s hooks and tools, in the typed document and in the
/// `state` the JSON spells.
#[allow(clippy::unwrap_used)]
fn verified_notices(
    home: &std::path::Path,
    project: &std::path::Path,
    pinned: &[(&str, HarnessId, Pin)],
    at: &str,
) {
    let verified = kendex(
        home,
        project,
        &["verify", "--scope", "project", "--strict", "--json"],
    );
    let printed = said(&verified);
    assert!(verified.status.success(), "{at}: {printed}");
    let document: Document = serde_json::from_slice(&verified.stdout)
        .unwrap_or_else(|error| panic!("{at}: verify document: {error}\n{printed}"));
    let expected: Vec<(&str, &str, Option<HarnessId>)> = pinned
        .iter()
        .map(|&(name, harness, _)| ("hook", name, Some(harness)))
        .collect();
    assert_eq!(notices(&document), expected, "{at}: {printed}");
    let wire: Vec<(String, String, String)> = expected
        .iter()
        .map(|&(kind, name, harness)| {
            (
                kind.to_owned(),
                name.to_owned(),
                harness.unwrap().name().to_owned(),
            )
        })
        .collect();
    assert_eq!(wire_notices(&verified.stdout), wire, "{at}: {printed}");
}

fn notices(document: &Document) -> Vec<(&str, &str, Option<HarnessId>)> {
    document
        .rows
        .iter()
        .filter(|row| row.state == State::Notice)
        .map(|row| (row.kind.as_str(), row.name.as_str(), row.harness))
        .collect()
}

/// The rows whose `state` the JSON spells `notice`, read apart from
/// [`State`] so a renamed variant cannot move the wire value unnoticed.
#[allow(clippy::unwrap_used)]
fn wire_notices(stdout: &[u8]) -> Vec<(String, String, String)> {
    let document: serde_json::Value = serde_json::from_slice(stdout).unwrap();
    document["rows"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["state"] == "notice")
        .map(|row| {
            let field = |key: &str| row[key].as_str().unwrap().to_owned();
            (field("kind"), field("name"), field("harness"))
        })
        .collect()
}
