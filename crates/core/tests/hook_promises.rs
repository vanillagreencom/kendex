//! What a hook install actually promises: which tools run the check and
//! which only read it as text, and whether the matcher it carries can match
//! anything where it lands.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::PathBuf;

use kendex_core::engine::{EngineReport, audit};
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
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"copy\"\n\n{declarations}",
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
/// whether that input was unreadable or excluded the requested harness.
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_hook_refusal_names_its_own_reason() {
    for (text, record) in [
        (
            "not a hook".to_owned(),
            "kendex-hook-unreadable: hook=guard",
        ),
        (
            GUARD.replace("# event:", "# harnesses: [claude]\n# event:"),
            "kendex-hook-excluded: hook=guard harness=codex source=catalog field=harnesses",
        ),
    ] {
        let f = fixture("\"codex\"", "[hooks.guard]\nsource = \"cat\"\n");
        fs::write(f.env.home.join("catalog/hooks/guard.sh"), text).unwrap();
        let report = plan(&f);
        assert!(
            report
                .notes
                .iter()
                .any(|note| note.lines().next() == Some(record)),
            "{record}: {:?}",
            report.notes
        );
        kendex_core::apply::execute(&f.env, &report.plan).unwrap();
        let Scope::Project { root } = &f.scope else {
            panic!("fixture is a project")
        };
        assert!(!root.join(".codex/hooks.json").exists(), "{record}");
    }
}
