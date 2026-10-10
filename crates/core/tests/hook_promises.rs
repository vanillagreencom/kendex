//! What a hook install actually promises: which tools run the check and
//! which only read it as text, and whether the matcher it carries can match
//! anything where it lands.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::PathBuf;

use kendex_core::engine::{DeclarationStatus, EngineReport, audit, plan_record_existing};
use kendex_core::env::{Env, FakeOs};
use kendex_core::harness::{Enforcement, hook_enforcement};
use kendex_core::model::{HarnessId, ItemKind, Scope};

/// Authored in Claude's vocabulary, like every hook a catalog ships.
const GUARD: &str = "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: check shell commands\n# ---\nexit 0\n";

/// A matcher that is a regex, not a tool name.
const LOOSE: &str = "#!/usr/bin/env bash\n# ---\n# name: loose\n# event: PreToolUse\n# matcher: Bash.*\n# harnesses: [gemini, copilot, antigravity]\n# description: check shell commands\n# ---\nexit 0\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
}

#[allow(clippy::unwrap_used)]
fn fixture(harnesses: &str, declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project: PathBuf = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(source.join("hooks/guard.sh"), GUARD).unwrap();
    fs::write(source.join("hooks/loose.sh"), LOOSE).unwrap();
    // Hooks install only from a catalog that declares kendex's layout.
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 7\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"copy\"\n\n{declarations}",
            source_path(&source)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project { root: project },
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn plan(f: &Fixture) -> EngineReport {
    audit(&f.env, &f.scope).unwrap()
}

#[allow(clippy::unwrap_used)]
fn fixture_with_newer_hook(harnesses: &str, event: &str) -> Fixture {
    let f = fixture(
        "\"claude\", \"codex\", \"opencode\", \"cursor\", \"gemini\"",
        &format!(
            "[hooks.guard]\nsource = \"cat\"\nharnesses = [\"claude\"]\n[hooks.newer]\nsource = \"cat\"\nharnesses = [{harnesses}]\n"
        ),
    );
    fs::write(
        f.env.home.join("catalog/hooks/newer.sh"),
        GUARD
            .replace("name: guard", "name: newer")
            .replace("PreToolUse", event),
    )
    .unwrap();
    f
}

const UNSUPPORTED_DELIVERIES: [(&str, &str, &[HarnessId], &[HarnessId]); 8] = {
    use HarnessId::{Antigravity, Claude, Codex, Copilot, Cursor, Gemini, Opencode, Pi};
    [
        (
            "\"claude\", \"opencode\", \"cursor\"",
            "FutureCatalogEvent",
            &[Claude],
            &[Opencode, Cursor],
        ),
        (
            "\"claude\", \"gemini\"",
            "PermissionRequest",
            &[Gemini],
            &[Claude],
        ),
        ("\"claude\", \"pi\"", "PermissionRequest", &[Pi], &[Claude]),
        ("\"claude\", \"codex\"", "StopFailure", &[Codex], &[Claude]),
        (
            "\"claude\", \"copilot\"",
            "TaskCompleted",
            &[Copilot],
            &[Claude],
        ),
        (
            "\"claude\", \"antigravity\"",
            "SessionStart",
            &[Antigravity],
            &[Claude],
        ),
        ("\"claude\"", "FutureCatalogEvent", &[Claude], &[]),
        (
            "\"codex\", \"gemini\"",
            "TaskCompleted",
            &[Codex, Gemini],
            &[],
        ),
    ]
};

/// Supported copies still land. Each unsupported copy fails delivery,
/// even when other copies land. Record recovery requires full delivery.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_records_supported_copies_but_fails_each_unsupported_delivery() {
    for (harnesses, event, unavailable, delivered) in UNSUPPORTED_DELIVERIES {
        let f = fixture_with_newer_hook(harnesses, event);
        let report = plan(&f);
        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Incomplete,
            "{report:?}"
        );
        let failures: Vec<_> = report
            .drift
            .iter()
            .filter(|row| {
                row.name == "newer" && row.state == kendex_core::engine::DriftState::Conflict
            })
            .collect();
        assert_eq!(failures.len(), unavailable.len(), "{report:?}");
        let deliveries: std::collections::BTreeSet<_> = report
            .failed_hook_deliveries()
            .map(|row| (row.kind, row.name.as_str(), row.harness))
            .collect();
        assert_eq!(
            deliveries,
            unavailable
                .iter()
                .map(|&harness| (ItemKind::Hook, "newer", harness))
                .collect(),
            "{report:?}"
        );
        for &harness in unavailable {
            let row = failures.iter().find(|row| row.harness == harness).unwrap();
            assert_eq!(row.kind, ItemKind::Hook);
            assert_eq!(
                row.detail.lines().next(),
                Some(
                    format!(
                        "kendex-hook-unsupported: harness={} event={event} hook=newer",
                        harness.name()
                    )
                    .as_str()
                )
            );
        }
        assert!(
            !report
                .notes
                .iter()
                .any(|note| note.starts_with("kendex-hook-unsupported:"))
        );
        assert!(
            !report
                .warnings
                .iter()
                .any(|warning| warning.message.starts_with("kendex-hook-unsupported:"))
        );

        kendex_core::apply::execute(&f.env, &report.plan).unwrap();
        let path = kendex_core::lock::lock_path(&f.env, &f.scope);
        let lock = kendex_core::lock::load(&path).unwrap();
        assert!(lock.entries.contains_key("hook:guard:claude"));
        let recorded: std::collections::BTreeSet<_> = lock
            .entries
            .values()
            .filter(|entry| entry.name == "newer")
            .map(|entry| entry.harness)
            .collect();
        assert_eq!(recorded, delivered.iter().copied().collect(), "{harnesses}");
        fs::remove_file(&path).unwrap();
        let recovery = plan_record_existing(&f.env, &f.scope);
        assert!(
            matches!(
                recovery,
                Err(kendex_core::error::CoreError::RecordExistingRefused { .. })
            ),
            "{recovery:?}"
        );
    }
}

/// Cursor and OpenCode have no hook surface of their own: what installs
/// there is prose the model is free to ignore. Presenting that as the same
/// protection Claude Code runs is the failure the enforcement axis exists
/// to prevent. The warning and typed enforcement result must agree.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_says_which_tools_run_it_and_which_only_read_it() {
    let f = fixture(
        "\"claude\", \"codex\", \"opencode\", \"cursor\", \"pi\", \"gemini\", \"copilot\"",
        "[hooks.guard]\nsource = \"cat\"\n",
    );
    let report = plan(&f);

    assert_eq!(report.failed_hook_deliveries().count(), 0, "{report:?}");
    let advisory: Vec<_> = report
        .warnings
        .iter()
        .filter(|warning| warning.kind == ItemKind::Hook && warning.name == "guard")
        .map(|warning| {
            (
                warning.harness,
                warning.remediation.is_some(),
                warning.message.lines().next(),
            )
        })
        .collect();
    assert_eq!(
        advisory,
        [
            (
                Some(HarnessId::Opencode),
                true,
                Some("kendex-hook-advisory: harness=opencode hook=guard")
            ),
            (
                Some(HarnessId::Cursor),
                true,
                Some("kendex-hook-advisory: harness=cursor hook=guard")
            ),
            (
                Some(HarnessId::Pi),
                true,
                Some("kendex-hook-carrier-missing: harness=pi hook=guard carrier=pi-hooks")
            ),
        ]
    );

    for (harness, expected) in [
        (HarnessId::Opencode, Enforcement::Advisory),
        (HarnessId::Cursor, Enforcement::Advisory),
        (HarnessId::Pi, Enforcement::Advisory),
        (HarnessId::Claude, Enforcement::Enforced),
        (HarnessId::Codex, Enforcement::Enforced),
        (HarnessId::Gemini, Enforcement::Enforced),
        (HarnessId::Copilot, Enforcement::Enforced),
    ] {
        assert_eq!(
            hook_enforcement(&f.env, &f.scope, harness),
            expected,
            "{harness:?}"
        );
    }
}

/// A matcher is a regex over each tool's own tool names. kendex translates
/// the names it knows and leaves the rest exactly as authored — and says so,
/// because a matcher that never matches is a protection that never runs.
#[test]
#[allow(clippy::unwrap_used)]
fn a_matcher_that_cannot_be_translated_installs_as_written_and_is_named() {
    let f = fixture(
        "\"gemini\", \"copilot\", \"antigravity\"",
        "[hooks.loose]\nsource = \"cat\"\n",
    );
    let report = plan(&f);

    let named: Vec<_> = report
        .warnings
        .iter()
        .filter(|w| w.kind == ItemKind::Hook && w.name == "loose")
        .map(|w| (w.harness, w.message.lines().next()))
        .collect();
    assert_eq!(
        named,
        [
            (
                Some(HarnessId::Gemini),
                Some("kendex-hook-matcher-untranslated: harness=gemini hook=loose matcher=Bash.*")
            ),
            (
                Some(HarnessId::Copilot),
                Some("kendex-hook-matcher-untranslated: harness=copilot hook=loose matcher=Bash.*")
            ),
            (
                Some(HarnessId::Antigravity),
                Some(
                    "kendex-hook-matcher-untranslated: harness=antigravity hook=loose matcher=Bash.*"
                )
            )
        ],
        "{:?}",
        report.warnings
    );

    kendex_core::apply::execute(&f.env, &report.plan).unwrap();
    let Scope::Project { root } = &f.scope else {
        panic!("the fixture is a project");
    };
    let registered = |path: PathBuf| -> serde_json::Value {
        serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
    };
    for (path, matcher) in [
        (".gemini/settings.json", vec!["hooks", "BeforeTool"]),
        (".github/hooks/loose.json", vec!["hooks", "preToolUse"]),
        (".agents/hooks.json", vec!["loose", "PreToolUse"]),
    ] {
        assert_eq!(
            registered(root.join(path))[matcher[0]][matcher[1]][0]["matcher"],
            "Bash.*",
            "{path}"
        );
    }
}

/// Catalog scripts supply their own frontmatter; a refused script names
/// whether that input was unreadable or excluded the requested harness. An
/// exclusion is a note only where the person's declaration of the hook
/// names the tool the header leaves out: with `harnesses` unset on the
/// declaration it is expected state, carried as `excluded_hooks` and not
/// said. One row per shape, and nothing lands on the excluded tool in any.
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_hook_refusal_names_its_own_reason() {
    let excluding = GUARD
        .replace("# event:", "# harnesses: [claude]\n# event:")
        .replace("PreToolUse", "PermissionRequest");
    let excluded = || {
        vec![kendex_core::engine::ExcludedHook {
            name: "guard".to_owned(),
            harness: HarnessId::Codex,
        }]
    };
    type Row = (
        &'static str,
        String,
        &'static str,
        Option<&'static str>,
        Vec<kendex_core::engine::ExcludedHook>,
    );
    let rows: [Row; 3] = [
        (
            "an unreadable header",
            "not a hook".to_owned(),
            "[hooks.guard]\nsource = \"cat\"\n",
            Some("kendex-hook-unreadable: hook=guard"),
            vec![],
        ),
        (
            "a declaration that leaves harnesses unset",
            excluding.clone(),
            "[hooks.guard]\nsource = \"cat\"\n",
            None,
            excluded(),
        ),
        (
            "a declaration naming the excluded tool",
            excluding,
            "[hooks.guard]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
            Some("kendex-hook-excluded: hook=guard harness=codex source=catalog field=harnesses"),
            vec![],
        ),
    ];
    for (case, text, declaration, record, want_excluded) in rows {
        let f = fixture("\"codex\"", declaration);
        fs::write(f.env.home.join("catalog/hooks/guard.sh"), text).unwrap();
        let report = plan(&f);
        let heads: Vec<&str> = report
            .notes
            .iter()
            .filter_map(|note| note.lines().next())
            .filter(|head| head.starts_with("kendex-hook-"))
            .collect();
        assert_eq!(heads, Vec::from_iter(record), "{case}: {:?}", report.notes);
        assert_eq!(report.excluded_hooks, want_excluded, "{case}");
        assert_eq!(
            report.failed_hook_deliveries().count(),
            0,
            "{case}: {report:?}"
        );
        assert!(
            !report
                .drift
                .iter()
                .any(|row| row.state == kendex_core::engine::DriftState::Conflict),
            "{case}: {report:?}"
        );
        assert_eq!(
            report.declaration_status,
            if case == "an unreadable header" {
                DeclarationStatus::Incomplete
            } else {
                DeclarationStatus::Complete
            }
        );
        kendex_core::apply::execute(&f.env, &report.plan).unwrap();
        let Scope::Project { root } = &f.scope else {
            panic!("fixture is a project")
        };
        assert!(!root.join(".codex/hooks.json").exists(), "{case}");
    }
}
