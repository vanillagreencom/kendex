//! `kendex verify` and a hook's `harnesses` pin, on a `[hooks.<n>]`
//! declaration or a `[[custom-hooks]]` entry: each tool the pin decides
//! against the hook's own reading is a `notice` row naming the hook and the
//! tool, which leaves the run clean under `--strict`, whether the hook is
//! switched on or off. A pin that decides nothing the hook would not decide
//! itself prints none, and so does one leaving out a tool where a companion
//! the hook requires could not run beside it, or where a name it requires
//! resolves to nothing. The engine's record of what
//! the pin does on each tool, which picks the remedy verify prints, is
//! checked beside the rows, and each notice row's `state` is read as the
//! JSON spells it. A plan not asked to judge pins records none: only
//! verify reads them. That such a plan also skips the walk with each pin
//! dropped changes no output, only its cost, so no row holds it.
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
//!   `pin_answers` only the tools the scope installs on loses the Codex
//!   record, and asking a tool twice repeats the Copilot one;
//! - the same row's run naming the set: dropping the names filter in
//!   `verify::pinned_hook_rows` prints the pinned hook's notices;
//! - the switched-off rows: asking `pin_answers` through `not_written`,
//!   whose switched-off answer comes first, empties their notices;
//! - the companion row: `pin_records` no longer reading
//!   `DesiredState::withheld_past_pin` in its leave-out arm puts a notice
//!   on the requiring hook for the tool its companion's pin leaves out;
//! - the two-level row, where the hook requires a companion that requires
//!   a pinned third: asking only the hook's own companions with its pin
//!   dropped, and not the walk (`deps::withheld_past_pin`), puts a notice
//!   on the hook;
//! - the bundled companion row: the walk asking past the pin only the
//!   tools the scope installs on, and not the expansion's aims
//!   (`deps::wanted_by`), puts a notice on the hook for Codex;
//! - the missing-name rows: the walk withholding no hook on a tool where a
//!   name it requires resolves to nothing (`deps::wanted_by`) puts a
//!   notice on the hook;
//! - the peer row, where another hook brings the companions onto Copilot
//!   first: the walk with the pin dropped going on only to a companion
//!   that learns a reason, and not to every one the hook requires below it
//!   (`deps::walk`), puts a notice on the hook;
//! - the switched-off missing-name row: the walk with the pin dropped
//!   keeping the hook's switch (`deps::withheld_past_pin`) puts a notice
//!   on the hook;
//! - the custom-hook rows: dropping the `pins_left_out` call in
//!   `desired_custom_hooks` empties the Claude-only entry's notices;
//!   `unlisted_tools` counting only a registered delivery empties the
//!   scoped entry's, counting only a registered or agent-file one empties
//!   the OpenCode entry's, and counting a tool where the entry is not
//!   installable puts a notice on the Antigravity entry;
//! - every row with a pin record: a plan judging pins unasked
//!   (`desired_kinds::pin_records` ignoring `DesiredState::judge_pins`)
//!   fills the unjudged plan's records, and verify's reading no longer
//!   asking for them (`attest::Reading::plan_options`) empties the
//!   notices;
//! - every row with a notice: renaming `State::Notice`, or its wire
//!   spelling, empties the notices read off the JSON.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;

use kendex_core::attest::{Document, State};
use kendex_core::engine::{Pin, PinnedHook, PlanOptions};
use kendex_core::env::Env;
use kendex_core::model::{HarnessId, Scope};

use super::verify_records::{kendex, said, write};

const HOOK: &str = "guard";
/// A hook [`HOOK`] requires where a case says so.
const COMPANION: &str = "judge";
/// A hook [`COMPANION`] requires where a case says so.
const INNER: &str = "inner";
/// A name the hook requires where a case says so, which the catalog holds
/// nothing under.
const MISSING: &str = "absent";
/// A second hook, declared with no pin, that requires [`COMPANION`] where
/// a case says so.
const PEER: &str = "peer";
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
    /// The `harnesses` pin on a declaration of [`INNER`], which an
    /// undeclared [`COMPANION`] then requires and the hook requires
    /// [`COMPANION`], or `None` for neither.
    inner: Option<&'static str>,
    /// Whether the hook also requires [`MISSING`], and holds its
    /// requirements on Copilot alone.
    missing: bool,
    /// Whether [`PEER`] is declared, and the hook requires [`COMPANION`],
    /// which requires an undeclared [`INNER`] that requires [`MISSING`] on
    /// Copilot alone: the peer brings both onto Copilot before the hook's
    /// pin is dropped.
    peer: bool,
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
    inner: None,
    missing: false,
    peer: false,
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
    // The same a level down: the companion the hook brings in requires
    // a hook whose pin keeps it off Copilot, so the companion is withheld
    // there and the hook with it, pin or no pin.
    Case {
        pin: Some("[\"claude\"]"),
        inner: Some("[\"claude\"]"),
        recorded: &[HarnessId::Claude],
        pinned: &[(INNER, HarnessId::Copilot, Pin::LeavesOut)],
        ..PLAIN
    },
    // The set carries the hook onto Codex as well, where its companion's
    // pin keeps the companion off too: the hook's pin decides nothing on
    // either tool.
    Case {
        pin: Some("[\"claude\"]"),
        bundled: true,
        companion: Some("[\"claude\"]"),
        recorded: &[HarnessId::Claude],
        pinned: &[(COMPANION, HarnessId::Copilot, Pin::LeavesOut)],
        ..PLAIN
    },
    // A name the hook requires on Copilot that the catalog does not hold
    // withholds the hook there, pin or no pin.
    Case {
        pin: Some("[\"claude\"]"),
        missing: true,
        recorded: &[HarnessId::Claude],
        ..PLAIN
    },
    // Switched off, the hook is judged as if it were on: the name would
    // still withhold it from Copilot with the pin dropped.
    Case {
        pin: Some("[\"claude\"]"),
        switched_off: true,
        missing: true,
        recorded: &[HarnessId::Claude],
        ..PLAIN
    },
    // Two levels down, where another hook already brings the companions
    // onto Copilot: the name the inner one lacks there withholds it, the
    // companion and the hook, pin or no pin.
    Case {
        pin: Some("[\"claude\"]"),
        peer: true,
        recorded: &[HarnessId::Claude],
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
        "header {:?} pin {:?} bundled {} off {} companion {:?} inner {:?} missing {} peer {}",
        case.header,
        case.pin,
        case.bundled,
        case.switched_off,
        case.companion,
        case.inner,
        case.missing,
        case.peer
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
    let (env, scope) = (
        Env::host_rooted(&home),
        Scope::Project {
            root: project.clone(),
        },
    );
    let judged = PlanOptions {
        judge_pins: true,
        ..PlanOptions::current()
    };
    let report = kendex_core::engine::plan_apply(&env, &scope, &judged).unwrap();
    let unjudged = kendex_core::engine::audit(&env, &scope).unwrap();
    assert_eq!(unjudged.pinned_hooks, [], "{at}");
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
    let required: Vec<&str> = [
        (
            case.companion.is_some() || case.inner.is_some() || case.peer,
            COMPANION,
        ),
        (case.missing, MISSING),
    ]
    .into_iter()
    .filter_map(|(wanted, name)| wanted.then_some(name))
    .collect();
    let requires = match required.is_empty() {
        true => String::new(),
        false => format!("# requires: [{}]\n", required.join(", ")),
    };
    let requires_on = match case.missing {
        true => "# requires-on: [copilot]\n",
        false => "",
    };
    let requires_inner = match case.inner.is_some() || case.peer {
        true => format!("# requires: [{INNER}]\n"),
        false => String::new(),
    };
    let inner_requires = match case.peer {
        true => format!("# requires: [{MISSING}]\n# requires-on: [copilot]\n"),
        false => String::new(),
    };
    write(
        &catalog.join(format!("hooks/{HOOK}.sh")),
        &format!(
            "#!/usr/bin/env bash\n# ---\n# name: {HOOK}\n# event: PreToolUse\n# matcher: Bash\n# description: guards\n{}{requires}{requires_on}# ---\nexit 0\n",
            case.header
        ),
    );
    write(
        &catalog.join(format!("hooks/{COMPANION}.sh")),
        &format!(
            "#!/usr/bin/env bash\n# ---\n# name: {COMPANION}\n# event: Stop\n# description: judges\n{requires_inner}# ---\nexit 0\n"
        ),
    );
    write(
        &catalog.join(format!("hooks/{INNER}.sh")),
        &format!(
            "#!/usr/bin/env bash\n# ---\n# name: {INNER}\n# event: Stop\n# description: delivers\n{inner_requires}# ---\nexit 0\n"
        ),
    );
    write(
        &catalog.join(format!("hooks/{PEER}.sh")),
        &format!(
            "#!/usr/bin/env bash\n# ---\n# name: {PEER}\n# event: PreToolUse\n# matcher: Bash\n# description: also guards\n# requires: [{COMPANION}]\n# ---\nexit 0\n"
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
    let inner = case
        .inner
        .map(|list| format!("[hooks.{INNER}]\nsource = \"cat\"\nharnesses = {list}\n"))
        .unwrap_or_default();
    let peer = match case.peer {
        true => format!("[hooks.{PEER}]\nsource = \"cat\"\n"),
        false => String::new(),
    };
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\", \"copilot\"]\nmethod = \"copy\"\n{bundle}{companion}{inner}{peer}[hooks.{HOOK}]\nsource = \"cat\"\n{pin}{switch}",
            source_path(catalog),
        ),
    );
}

/// What one `[[custom-hooks]]` entry's list does where `[install]` names
/// some tools: the tools verify names in a notice row.
struct Custom {
    /// The entry's `harnesses` value, or `None` for no list.
    list: Option<&'static str>,
    /// Whether the entry says `enabled = false`.
    switched_off: bool,
    /// The agents the entry runs for.
    agents: &'static str,
    /// The `[install] harnesses` value.
    install: &'static str,
    /// The tools verify names in a notice row.
    named: &'static [HarnessId],
}

const UNLISTED: Custom = Custom {
    list: None,
    switched_off: false,
    agents: "all",
    install: "[\"claude\", \"copilot\"]",
    named: &[],
};

const CUSTOM: &[Custom] = &[
    Custom {
        list: Some("[\"claude\"]"),
        named: &[HarnessId::Copilot],
        ..UNLISTED
    },
    Custom {
        list: Some("[\"claude\"]"),
        switched_off: true,
        named: &[HarnessId::Copilot],
        ..UNLISTED
    },
    UNLISTED,
    Custom {
        list: Some("[\"claude\", \"copilot\"]"),
        ..UNLISTED
    },
    // An entry for one agent goes into that agent's file on Claude Code,
    // which its list leaves out as it does a registry.
    Custom {
        list: Some("[\"copilot\"]"),
        agents: "reviewer",
        named: &[HarnessId::Claude],
        ..UNLISTED
    },
    // OpenCode writes the entry as prose, which its list leaves out as it
    // does a registry.
    Custom {
        list: Some("[\"claude\"]"),
        install: "[\"claude\", \"opencode\"]",
        named: &[HarnessId::Opencode],
        ..UNLISTED
    },
    // Antigravity takes no entry without a list naming it, so a list
    // leaving it out decides nothing there.
    Custom {
        list: Some("[\"claude\"]"),
        install: "[\"claude\", \"antigravity\"]",
        ..UNLISTED
    },
];

#[test]
#[allow(clippy::unwrap_used)]
fn a_custom_hook_list_is_judged_as_a_hook_pin_is() {
    for custom in CUSTOM {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = home.join("consumer");
        let list = custom
            .list
            .map(|list| format!("harnesses = {list}\n"))
            .unwrap_or_default();
        let switch = match custom.switched_off {
            true => "enabled = false\n",
            false => "",
        };
        let (install, agents) = (custom.install, custom.agents);
        write(
            &project.join("kendex.toml"),
            &format!(
                "schema = 6\n[install]\nharnesses = {install}\nmethod = \"copy\"\n\n[[custom-hooks]]\nname = \"{HOOK}\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./guard.sh\"\nagents = \"{agents}\"\n{list}{switch}"
            ),
        );
        fs::create_dir_all(project.join(".claude")).unwrap();
        fs::create_dir_all(project.join(".github")).unwrap();
        let at = format!(
            "list {list:?} off {} agents {agents} install {install}",
            custom.switched_off
        );
        let applied = kendex(&home, &project, &["apply", "-y", "--leave"]);
        assert!(applied.status.success(), "{at}: {}", said(&applied));
        let pinned: Vec<(&str, HarnessId, Pin)> = custom
            .named
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
