//! `[command-instructions]`: the project's text for a package command,
//! carried into every tool's copy while the publisher's body keeps
//! updating, so keeping a paragraph never means copying the command.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::harness::installs_here;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use serde_json::Value;

const SCRUB: &str =
    "---\ndescription: Scrub the code\n---\n\nScrub the diff named in $ARGUMENTS.\n";
const MERGE_REVIEW: &str = "Merge review: a second reviewer signs off before merge.";
const RISK_POLICY: &str = "Risk policy: a migration ships behind a flag.";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

/// Every tool that takes a command at project scope, native or converted,
/// read off the capability table rather than named here.
fn command_tools(scope: &Scope) -> Vec<HarnessId> {
    HarnessId::ALL
        .into_iter()
        .filter(|harness| installs_here(*harness, ItemKind::Command, scope))
        .collect()
}

/// A project declaring the catalog's `code-scrub` command on every tool
/// that takes one, with `extra` appended to its manifest.
#[allow(clippy::unwrap_used)]
fn fixture(extra: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };

    let source = home.join("catalog");
    fs::create_dir_all(source.join("commands")).unwrap();
    fs::write(source.join("commands/code-scrub.md"), SCRUB).unwrap();
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();

    let harnesses = command_tools(&scope)
        .iter()
        .map(|harness| format!("\"{}\"", harness.name()))
        .collect::<Vec<_>>()
        .join(", ");
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"copy\"\n\n[commands.code-scrub]\nsource = \"cat\"\n\n{extra}",
            source_path(&source)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope,
        project,
        source,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

/// What each tool loads for the command, found where the lock says the
/// install wrote it: a file, or the SKILL.md of a generated skill tree.
#[allow(clippy::unwrap_used)]
fn outputs(f: &Fixture) -> Vec<(HarnessId, String)> {
    let lock: Value =
        serde_json::from_str(&fs::read_to_string(f.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    command_tools(&f.scope)
        .into_iter()
        .map(|harness| {
            let key = format!("command:code-scrub:{}", harness.name());
            let written = lock["entries"][&key]["emitted"]["paths"][0]
                .as_str()
                .unwrap_or_else(|| panic!("{key} records no written path"));
            let mut path = f.project.join(written);
            if path.is_dir() {
                path.push("SKILL.md");
            }
            (harness, fs::read_to_string(&path).unwrap())
        })
        .collect()
}

const INSTRUCTED: &str = "[command-instructions]\ncode-scrub = \"\"\"\nMerge review: a second reviewer signs off before merge.\n\nRisk policy: a migration ships behind a flag.\n\"\"\"\n";

/// The consumer keeps both paragraphs across a publisher update, in every
/// tool's copy exactly once, and the update itself still lands.
#[test]
#[allow(clippy::unwrap_used)]
fn the_consumer_paragraphs_ride_every_copy_through_a_publisher_update() {
    let f = fixture(INSTRUCTED);
    assert!(command_tools(&f.scope).contains(&HarnessId::Codex));
    assert!(command_tools(&f.scope).contains(&HarnessId::Gemini));
    apply_now(&f);
    for (harness, text) in outputs(&f) {
        assert_eq!(text.matches(MERGE_REVIEW).count(), 1, "{harness:?}: {text}");
        assert_eq!(text.matches(RISK_POLICY).count(), 1, "{harness:?}: {text}");
        assert!(text.contains("Scrub the diff"), "{harness:?}: {text}");
    }

    fs::write(
        f.source.join("commands/code-scrub.md"),
        "---\ndescription: Scrub the code\n---\n\nScrub every changed file.\n",
    )
    .unwrap();
    apply_now(&f);
    for (harness, text) in outputs(&f) {
        assert_eq!(text.matches(MERGE_REVIEW).count(), 1, "{harness:?}: {text}");
        assert_eq!(text.matches(RISK_POLICY).count(), 1, "{harness:?}: {text}");
        assert!(
            text.contains("Scrub every changed file."),
            "{harness:?}: {text}"
        );
        assert!(!text.contains("Scrub the diff"), "{harness:?}: {text}");
    }
    assert!(audit(&f.env, &f.scope).unwrap().drift.is_empty());
}

/// Instructions edited on their own reach every copy on the next apply,
/// replacing the block rather than stacking another.
#[test]
#[allow(clippy::unwrap_used)]
fn changed_instructions_replace_the_block_in_every_copy() {
    let f = fixture(INSTRUCTED);
    apply_now(&f);
    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(&manifest, text.replace("behind a flag", "behind two flags")).unwrap();
    apply_now(&f);
    for (harness, text) in outputs(&f) {
        assert!(!text.contains(RISK_POLICY), "{harness:?}: {text}");
        assert_eq!(
            text.matches("a migration ships behind two flags").count(),
            1,
            "{harness:?}: {text}"
        );
        assert_eq!(text.matches(MERGE_REVIEW).count(), 1, "{harness:?}: {text}");
    }
}

/// With nothing configured for the command — none at all, or only another
/// command's — every copy is the bytes the publisher's command renders to
/// without the table.
#[test]
#[allow(clippy::unwrap_used)]
fn unset_instructions_leave_every_copy_as_it_was() {
    let bare = fixture("");
    apply_now(&bare);
    let before = outputs(&bare);
    assert_eq!(
        fs::read_to_string(bare.project.join(".claude/commands/code-scrub.md")).unwrap(),
        SCRUB
    );
    let elsewhere = fixture("[command-instructions]\nother = \"Not this one.\"\n");
    apply_now(&elsewhere);
    assert_eq!(outputs(&elsewhere), before);
}

/// A retired agent label in a command's instructions renders under the
/// agent's current name, as it does in skill and agent instructions, and
/// the plan names the old one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_legacy_agent_label_renders_under_the_current_name() {
    let f = fixture(
        "[command-instructions]\ncode-scrub = \"Hand the risky part to agent:engineer.\"\n",
    );
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .warnings
            .iter()
            .any(|warning| warning.kind == ItemKind::Agent && warning.name == "engineer"),
        "warned about: {:?}",
        report
            .warnings
            .iter()
            .map(|warning| warning.name.as_str())
            .collect::<Vec<_>>()
    );
    apply::execute(&f.env, &report.plan).unwrap();
    for (harness, text) in outputs(&f) {
        assert_eq!(
            text.matches("agent:runtime.").count(),
            1,
            "{harness:?}: {text}"
        );
        assert!(!text.contains("agent:engineer"), "{harness:?}: {text}");
    }
}
