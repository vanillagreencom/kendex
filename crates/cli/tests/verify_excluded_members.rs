//! `kendex verify` and a declared hook whose own harnesses line names no
//! tool the consumer installs on: apply writes it nowhere and records
//! nothing for it, so verify passes it over and says so on one line. With
//! the tool configured the hook installs, and a record that lost its entry
//! still fails as a declaration the record does not hold.
//!
//! Controls, each a row the named defect turns red:
//! - the pass-over itself: the Codex-only rows, which the verify before it
//!   closed non-zero with the hook listed and not in the install record;
//! - every planned tool left out, not any one: the Claude-and-Codex row,
//!   where a hook installed on Claude prints no pass-over line;
//! - the hook's own name, the hook kind, and the record the rest still
//!   owe: the row that drops the sibling hook's and the same-named skill's
//!   entries, where both are gaps and neither is passed over;
//! - the names verify was asked about: the row naming only `tidy`, which
//!   prints no pass-over line;
//! - a missing record excused where every declaration is a hook its own
//!   harnesses line leaves off every configured tool: the two rows
//!   declaring the hook alone, through a bundle and directly, and the row
//!   declaring a bundle with no members, where verify passes;
//! - and only where every declaration is such a hook: the Codex row that
//!   deletes the record apply wrote for the bundle's other members, which
//!   verify refuses while it still prints the pass-over line;
//! - and only where the expansion read every declaration: the row whose
//!   second bundle comes from a source that is not there, which verify
//!   still refuses for its missing record;
//! - and only where the declarations were read at all: the row whose
//!   machine settings file does not parse, so the scope's audit fails,
//!   which verify still refuses for its missing record.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;

use super::verify_records::{git, kendex, row, said, write};

/// The consumer record holds no Copilot installations. Verify must not ask
/// for them, even when the catalog adds Copilot-only bundle members.
/// The fixture is a synthetic consumer: it takes the catalog's `workflow`
/// bundle on Claude, Codex and Pi, and its record holds only the
/// `lane-mail-check` hook. A local mirror supplies this checkout's catalog
/// without reaching the network.
/// The control restores verify's unfiltered declaration set in a disposable
/// source copy: the three Copilot-only hooks then produce `Unrecorded` rows.
#[test]
#[allow(clippy::unwrap_used)]
fn consumer_record_owes_no_copilot_only_workflow_hooks() {
    use kendex_core::attest::{Document, State};
    use kendex_core::engine::{DeclarationStatus, planned_closure};
    use kendex_core::env::Env;
    use kendex_core::model::{HarnessId, ItemKind, Scope};

    const EXCLUDED: &[&str] = &["lane-mail-compact", "lane-mail-prompt", "lane-mail-start"];
    // A workflow hook on Claude, Codex and Pi that the record lacks: verify
    // still owes it, so the exclusion is not a blanket pass on record gaps.
    const OWED: &str = "lane-mail-deliver";
    const MANIFEST: &str = include_str!("fixtures/example-consumer/manifest.toml");
    const RECORD: &str = include_str!("fixtures/example-consumer/install-record.json");

    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("consumer");
    write(&project.join("kendex.toml"), MANIFEST);
    write(&project.join(".kendex-lock.json"), RECORD);
    let env = Env::host_rooted(&home);
    let key = kendex_core::remote::cache_key(&env, "vanillagreencom/kendex");
    let mirror = kendex_core::remote::store::mirror_dir(&env, &key);
    fs::create_dir_all(mirror.parent().unwrap()).unwrap();
    git(
        &home,
        &[
            "clone",
            "--bare",
            test_util::checkout_root().to_str().unwrap(),
            mirror.to_str().unwrap(),
        ],
    );

    let manifest = kendex_core::manifest::load_current(&project.join("kendex.toml"))
        .unwrap()
        .unwrap();
    let (planned, status) = planned_closure(
        &env,
        &Scope::Project {
            root: project.clone(),
        },
        &manifest,
    );
    assert_eq!(
        status,
        DeclarationStatus::Complete,
        "catalog expansion must finish"
    );
    let record: serde_json::Value = serde_json::from_str(RECORD).unwrap();
    for name in EXCLUDED.iter().copied().chain([OWED]) {
        assert!(
            planned
                .iter()
                .any(|item| item.kind == ItemKind::Hook && item.name == name),
            "catalog expansion must reach hook {name}"
        );
        assert!(
            !record["entries"]
                .as_object()
                .unwrap()
                .values()
                .any(|entry| entry["kind"] == "hook" && entry["name"] == name),
            "consumer record must lack hook {name}"
        );
    }

    let mut args = vec!["verify", "--scope", "project", "--json", "lane-mail-check"];
    args.extend(EXCLUDED);
    args.push(OWED);
    let verified = kendex(&home, &project, &args);
    let document: Document = serde_json::from_slice(&verified.stdout)
        .unwrap_or_else(|error| panic!("verify document: {error}\n{}", said(&verified)));
    // Missing renders fail their rows in this read-only fixture. A recorded
    // sibling proves the audit ran; the assertion concerns only record gaps.
    let recorded_sibling = row(
        &document,
        "hook",
        "lane-mail-check",
        Some(HarnessId::Claude),
    );
    assert!(recorded_sibling.is_some(), "{}", said(&verified));
    let mut unrecorded: Vec<_> = document
        .rows
        .iter()
        .filter(|row| row.state == State::Unrecorded)
        .map(|row| (row.kind.as_str(), row.name.as_str(), row.harness))
        .collect();
    unrecorded.sort_unstable();
    assert_eq!(
        unrecorded,
        [
            ("hook", OWED, Some(HarnessId::Claude)),
            ("hook", OWED, Some(HarnessId::Codex)),
            ("hook", OWED, Some(HarnessId::Pi)),
        ],
        "listed/not-recorded: {unrecorded:?}\n{}",
        said(&verified)
    );
    for name in EXCLUDED {
        assert!(
            !document
                .rows
                .iter()
                .any(|row| row.kind == "hook" && row.name == *name),
            "excluded hook {name} must have no verification row"
        );
    }
}

/// The one line a scope prints for the hook it passed over.
const PASSED_OVER: &str = "1 package installs on no tool here, its own harnesses line names none of them: hook claude-only";

/// Printed by a scope whose declarations the record does not all hold.
const GAP: &str = "listed and not in the install record";

/// Every package the catalog holds, and the bundles over them.
const CATALOG: &[(&str, &str)] = &[
    (
        "kendex.toml",
        "is_source_catalog = true\n\n[bundles.workflow]\ndescription = \"the workflow set\"\nskills = [\"tidy\", \"claude-only\"]\nhooks = [\"claude-only\", \"everywhere\"]\n\n[bundles.lone]\ndescription = \"the Claude hook alone\"\nhooks = [\"claude-only\"]\n\n[bundles.empty]\ndescription = \"nothing yet\"\n",
    ),
    (
        "skills/tidy/SKILL.md",
        "---\nname: tidy\ndescription: tidies\n---\nTidy.\n",
    ),
    (
        "skills/claude-only/SKILL.md",
        "---\nname: claude-only\ndescription: shares the hook's name\n---\nShare.\n",
    ),
    (
        "hooks/claude-only.sh",
        "#!/usr/bin/env bash\n# ---\n# name: claude-only\n# event: PreToolUse\n# matcher: Bash\n# description: runs on Claude alone\n# harnesses: [claude]\n# ---\nexit 0\n",
    ),
    (
        "hooks/everywhere.sh",
        "#!/usr/bin/env bash\n# ---\n# name: everywhere\n# event: PreToolUse\n# matcher: Bash\n# description: runs on every tool\n# ---\nexit 0\n",
    ),
];

const WORKFLOW: &str = "[bundles.workflow]\nsource = \"cat\"\n";
const CODEX: &str = "[\"codex\"]";
const CLAUDE_CODEX: &str = "[\"claude\", \"codex\"]";

/// What a row does between apply and verify.
#[derive(Debug)]
enum Edit {
    /// Leaves everything as apply wrote it.
    Keep,
    /// Deletes these entries from the record.
    Drop(&'static [&'static str]),
    /// Deletes the record file.
    Delete,
    /// Writes a machine settings file that does not parse, which the
    /// scope's audit reads and fails on.
    BreakSettings,
}

/// One consumer, what it does to its record, and what verify says.
struct Case {
    /// The tools the consumer installs on.
    tools: &'static str,
    /// The consumer's declarations.
    declares: &'static str,
    /// What the row does between apply and verify.
    edit: Edit,
    /// The package names verify is asked about.
    names: &'static [&'static str],
    /// Whether the record holds the hook on Claude; `None` for no record.
    recorded: Option<bool>,
    passes: bool,
    passed_over: bool,
    /// Each package the gap line names, in order.
    gap: &'static [&'static str],
    /// Whether verify refuses the scope for its missing record.
    refused: bool,
}

/// The table: each row a consumer the fixture applies, edits and verifies.
const CASES: &[Case] = &[
    Case {
        tools: CODEX,
        declares: WORKFLOW,
        edit: Edit::Keep,
        names: &[],
        recorded: Some(false),
        passes: true,
        passed_over: true,
        gap: &[],
        refused: false,
    },
    Case {
        tools: CLAUDE_CODEX,
        declares: WORKFLOW,
        edit: Edit::Keep,
        names: &[],
        recorded: Some(true),
        passes: true,
        passed_over: false,
        gap: &[],
        refused: false,
    },
    Case {
        tools: CLAUDE_CODEX,
        declares: WORKFLOW,
        edit: Edit::Drop(&["hook:claude-only:claude"]),
        names: &[],
        recorded: Some(true),
        passes: false,
        passed_over: false,
        gap: &["hook claude-only"],
        refused: false,
    },
    Case {
        tools: CODEX,
        declares: WORKFLOW,
        edit: Edit::Drop(&["skill:claude-only:codex", "hook:everywhere:codex"]),
        names: &[],
        recorded: Some(false),
        passes: false,
        passed_over: true,
        gap: &["skill claude-only", "hook everywhere"],
        refused: false,
    },
    Case {
        tools: CODEX,
        declares: WORKFLOW,
        edit: Edit::Keep,
        names: &["tidy"],
        recorded: Some(false),
        passes: true,
        passed_over: false,
        gap: &[],
        refused: false,
    },
    Case {
        tools: CODEX,
        declares: "[bundles.lone]\nsource = \"cat\"\n",
        edit: Edit::Keep,
        names: &[],
        recorded: None,
        passes: true,
        passed_over: true,
        gap: &[],
        refused: false,
    },
    Case {
        tools: CODEX,
        declares: "[hooks.claude-only]\nsource = \"cat\"\n",
        edit: Edit::Keep,
        names: &[],
        recorded: None,
        passes: true,
        passed_over: true,
        gap: &[],
        refused: false,
    },
    Case {
        tools: CODEX,
        declares: WORKFLOW,
        edit: Edit::Delete,
        names: &[],
        recorded: Some(false),
        passes: false,
        passed_over: true,
        gap: &[],
        refused: true,
    },
    Case {
        tools: CODEX,
        declares: "[bundles.empty]\nsource = \"cat\"\n",
        edit: Edit::Keep,
        names: &[],
        recorded: None,
        passes: true,
        passed_over: false,
        gap: &[],
        refused: false,
    },
    Case {
        tools: CODEX,
        declares: "[sources.gone]\npath = \"nowhere\"\n[bundles.lost]\nsource = \"gone\"\n[hooks.claude-only]\nsource = \"cat\"\n",
        edit: Edit::Keep,
        names: &[],
        recorded: None,
        passes: false,
        passed_over: true,
        gap: &[],
        refused: true,
    },
    Case {
        tools: CODEX,
        declares: "[hooks.claude-only]\nsource = \"cat\"\n",
        edit: Edit::BreakSettings,
        names: &[],
        recorded: None,
        passes: false,
        passed_over: false,
        gap: &[],
        refused: true,
    },
];

#[test]
fn a_hook_for_no_configured_tool_is_passed_over_and_one_that_installs_is_held_to_the_record() {
    for case in CASES {
        check(case);
    }
}

/// One row: apply the consumer, edit its record, verify, and read the
/// exit status and the lines verify printed.
#[allow(clippy::unwrap_used)]
fn check(case: &Case) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    let project = home.join("consumer");
    for (path, text) in CATALOG {
        write(&catalog.join(path), text);
    }
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = {}\nmethod = \"copy\"\n{}",
            source_path(&catalog),
            case.tools,
            case.declares
        ),
    );
    fs::create_dir_all(project.join(".claude")).unwrap();
    let at = format!("{} {} {:?}", case.tools, case.declares, case.edit);
    let applied = kendex(&home, &project, &["apply", "-y", "--leave"]);
    assert!(applied.status.success(), "{at}: {}", said(&applied));
    let record = project.join(".kendex-lock.json");
    let read = || -> serde_json::Value {
        serde_json::from_str(&fs::read_to_string(&record).unwrap()).unwrap()
    };
    match case.recorded {
        None => assert!(!record.exists(), "{at}"),
        Some(recorded) => {
            let lock = read();
            assert_eq!(
                lock["entries"]
                    .as_object()
                    .unwrap()
                    .contains_key("hook:claude-only:claude"),
                recorded,
                "{at}: {lock}"
            );
        }
    }
    match case.edit {
        Edit::Keep => {}
        Edit::Drop(keys) => {
            let mut lock = read();
            let entries = lock["entries"].as_object_mut().unwrap();
            for key in keys {
                assert!(entries.remove(*key).is_some(), "{at}: {key}");
            }
            fs::write(&record, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
        }
        Edit::Delete => fs::remove_file(&record).unwrap(),
        Edit::BreakSettings => write(
            &kendex_core::env::Env::host_rooted(&home).settings_file(),
            "not = [\n",
        ),
    }
    let mut args = vec!["verify", "--scope", "project"];
    args.extend(case.names);
    let verified = kendex(&home, &project, &args);
    let printed = said(&verified);
    assert_eq!(verified.status.success(), case.passes, "{at}: {printed}");
    assert_eq!(
        printed.contains(PASSED_OVER),
        case.passed_over,
        "{at}: {printed}"
    );
    assert_eq!(
        printed.contains(GAP),
        !case.gap.is_empty(),
        "{at}: {printed}"
    );
    if !case.gap.is_empty() {
        let headline = format!(
            "{} package{} {GAP}",
            case.gap.len(),
            if case.gap.len() == 1 { "" } else { "s" }
        );
        assert!(printed.contains(&headline), "{at}: {printed}");
    }
    for package in case.gap {
        assert!(
            printed.contains(&format!("{package} — kendex apply records it")),
            "{at}: {printed}"
        );
    }
    assert_eq!(
        printed.contains("not checked"),
        matches!(case.edit, Edit::BreakSettings),
        "{at}: the audit fails only on the broken settings: {printed}"
    );
    assert_eq!(
        printed.contains("no install record"),
        case.refused,
        "{at}: {printed}"
    );
}
