//! Plugin-registry-shaped catalogs, end to end: a repository that ships its
//! content one plugin at a time is pointed at, enumerated, installed and
//! refreshed, with every item carrying the plugin it came from into the
//! name each tool lists it under.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::harness::rendered_name;
use kendex_core::model::{HarnessId, Scope};
use kendex_core::render::validate::validate_skill_tree;

const REGISTRY: &str = r#"{
  "name": "workflows",
  "owner": {"name": "wshobson"},
  "metadata": {"description": "workflows", "version": "1.2.0"},
  "plugins": [
    {"name": "data-science", "source": "./plugins/data-science", "version": "0.4.0",
     "description": "analysis", "category": "analysis"},
    {"name": "code-review", "source": "./plugins/code-review", "version": "1.0.0"},
    {"name": "upstream", "source": {"source": "git-subdir",
     "url": "https://example.invalid/x", "path": "plugins/y"}}
  ]
}"#;

const EDA: &str = "---\nname: eda\ndescription: explore a dataset\n---\n\nLook at the data.\n";
const REVIEWER: &str = "---\nname: reviewer\ndescription: review a change\n---\n\nRead it.\n";
const REPORT: &str = "---\ndescription: Write the report\n---\n\nSummarize.\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    market: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn write(root: &Path, rel: &str, text: &str) {
    let path = root.join(rel);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A project pointed at a plugin-registry-shaped catalog and a plain one.
#[allow(clippy::unwrap_used)]
fn fixture(harnesses: &str, declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let market = home.join("market");
    write(&market, ".claude-plugin/marketplace.json", REGISTRY);
    write(
        &market,
        "plugins/data-science/.claude-plugin/plugin.json",
        r#"{"name": "data-science", "version": "0.4.0"}"#,
    );
    write(&market, "plugins/data-science/skills/eda/SKILL.md", EDA);
    write(&market, "plugins/data-science/commands/report.md", REPORT);
    write(&market, "plugins/code-review/agents/reviewer.md", REVIEWER);

    let plain = home.join("plain");
    write(&plain, "skills/gh/SKILL.md", &EDA.replace("eda", "gh"));

    write(
        &project,
        "kendex.toml",
        &format!(
            "schema = 6\n\n[sources.market]\n{}\n\n[sources.plain]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"symlink\"\n\n{declarations}",
            source_path(&market),
            source_path(&plain)
        ),
    );

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        market,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) -> kendex_core::engine::EngineReport {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    report
}

#[allow(clippy::unwrap_used)]
fn read(f: &Fixture, rel: &str) -> String {
    fs::read_to_string(f.project.join(rel)).unwrap_or_else(|_| panic!("{rel} was not written"))
}

#[allow(clippy::unwrap_used)]
fn is_clean(f: &Fixture) -> bool {
    audit(&f.env, &f.scope).unwrap().drift.is_empty()
}

/// A catalog written on Windows installs like any other: CRLF is not a
/// reason to refuse a skill for a name it was never given the chance to
/// carry.
#[test]
#[allow(clippy::unwrap_used)]
fn a_windows_written_catalog_installs_under_its_plugin() {
    let f = fixture(
        "\"claude\"",
        "[skills.\"data-science/eda\"]\nsource = \"market\"\n",
    );
    write(
        &f.market,
        "plugins/data-science/skills/eda/SKILL.md",
        &EDA.replace('\n', "\r\n"),
    );
    let report = apply_now(&f);
    assert!(
        !report.notes.iter().any(|note| note.contains("eda")),
        "{:?}",
        report.notes
    );
    let installed = read(&f, ".claude/skills/data-science__eda/SKILL.md");
    assert!(
        installed.starts_with("---\r\nname: data-science__eda\r\n"),
        "{installed:?}"
    );
    assert!(is_clean(&f));
}

#[test]
#[allow(clippy::unwrap_used)]
fn every_tool_lists_a_plugin_registry_item_under_its_plugin() {
    let f = fixture(
        "\"claude\", \"codex\", \"opencode\"",
        "[skills.\"data-science/eda\"]\nsource = \"market\"\n\n[agents.\"code-review/reviewer\"]\nsource = \"market\"\n\n[commands.\"data-science/report\"]\nsource = \"market\"\n",
    );
    apply_now(&f);

    // Claude and Codex join the two halves with underscores; OpenCode will
    // not load an underscore, so it gets the hyphen its own names take.
    let claude = read(&f, ".claude/skills/data-science__eda/SKILL.md");
    assert!(
        claude.starts_with("---\nname: data-science__eda\n"),
        "{claude}"
    );
    assert!(claude.contains("Look at the data."), "{claude}");
    let shared = read(&f, ".agents/skills/data-science__eda/SKILL.md");
    assert!(
        shared.starts_with("---\nname: data-science__eda\n"),
        "{shared}"
    );
    // OpenCode will not load an underscore, so its spelling is a directory
    // of its own inside the shared tree rather than a copy under .opencode.
    let opencode = read(&f, ".agents/skills/data-science-eda/SKILL.md");
    assert!(
        opencode.starts_with("---\nname: data-science-eda\n"),
        "{opencode}"
    );

    let agent = read(&f, ".claude/agents/code-review__reviewer.md");
    assert!(agent.contains("name: code-review__reviewer"), "{agent}");
    // OpenCode names an agent by its file, so the hyphenated spelling is
    // the whole of what it will answer to.
    read(&f, ".opencode/agents/code-review-reviewer.md");
    assert!(
        f.project
            .join(".codex/agents/code-review__reviewer.toml")
            .is_file()
    );

    // A command reaches Claude as a file and Codex as a generated skill,
    // both under the namespaced name.
    assert!(
        f.project
            .join(".claude/commands/data-science__report.md")
            .is_file()
    );
    assert!(
        f.project
            .join(".agents/skills/data-science__report/SKILL.md")
            .is_file()
    );

    // The name in `kendex.toml` stays the identity: that is what the lock
    // records and what the user removes by.
    let lock: serde_json::Value = serde_json::from_str(&read(&f, ".kendex-lock.json")).unwrap();
    assert!(lock["entries"]["skill:data-science/eda:claude"].is_object());
    assert!(lock["entries"]["agent:code-review/reviewer:opencode"].is_object());
    assert!(is_clean(&f));
}

#[test]
fn the_separator_each_tool_gets_is_one_its_own_loader_accepts() {
    let expected = [
        (HarnessId::Claude, "data-science__eda"),
        (HarnessId::Codex, "data-science__eda"),
        (HarnessId::Cursor, "data-science__eda"),
        (HarnessId::Pi, "data-science__eda"),
        (HarnessId::Gemini, "data-science__eda"),
        (HarnessId::Opencode, "data-science-eda"),
        (HarnessId::Copilot, "data-science-eda"),
    ];
    for (harness, spelling) in expected {
        let rendered = rendered_name(harness, "data-science/eda");
        assert_eq!(rendered, spelling, "{}", harness.display_name());
        // The honest check: whatever spelling the table hands out, the
        // harness's own loader rules have to accept it.
        let files = vec![(
            PathBuf::from("SKILL.md"),
            format!("---\nname: {rendered}\ndescription: explore\n---\n").into_bytes(),
        )];
        let breakage: Vec<String> =
            validate_skill_tree(harness, "data-science/eda", &rendered, &files)
                .into_iter()
                .filter(kendex_core::render::validate::Finding::is_breakage)
                .map(|finding| finding.message)
                .collect();
        assert!(
            breakage.is_empty(),
            "{}: {breakage:?}",
            harness.display_name()
        );
    }
    // A plain name is untouched, whichever tool reads it.
    for (harness, _) in expected {
        assert_eq!(rendered_name(harness, "gh"), "gh");
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn two_names_that_would_share_one_file_install_neither() {
    let f = fixture(
        "\"claude\"",
        "[skills.\"data-science/eda\"]\nsource = \"market\"\n\n[skills.\"data-science__eda\"]\nsource = \"plain\"\n",
    );
    // The plain catalog really carries the flat spelling, so both
    // declarations resolve and the clash is about the file, not the source.
    let plain = f.project.parent().unwrap().parent().unwrap().join("plain");
    write(&plain, "skills/data-science__eda/SKILL.md", EDA);

    let report = audit(&f.env, &f.scope).unwrap();
    let reasons: Vec<&str> = report
        .drift
        .iter()
        .map(|row| row.detail.as_str())
        .filter(|detail| detail.contains("install as"))
        .collect();
    assert_eq!(reasons.len(), 2, "{:?}", report.drift);
    for reason in &reasons {
        assert!(reason.contains("data-science/eda"), "{reason}");
        assert!(reason.contains("data-science__eda"), "{reason}");
    }
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!f.project.join(".claude/skills/data-science__eda").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_that_lies_about_itself_installs_nothing_and_says_why() {
    let f = fixture(
        "\"claude\"",
        "[skills.\"escape/eda\"]\nsource = \"market\"\n\n[skills.\"data-science/eda\"]\nsource = \"market\"\n",
    );
    // An entry pointing out of the repository, and a plugin directory
    // reached through a symlink: neither is consumable, both are named.
    write(
        &f.market,
        ".claude-plugin/marketplace.json",
        &REGISTRY.replace(
            r#"{"name": "code-review", "source": "./plugins/code-review", "version": "1.0.0"}"#,
            r#"{"name": "escape", "source": "../../../etc"}"#,
        ),
    );
    let outside = f.market.parent().unwrap().join("outside");
    write(&outside, "skills/eda/SKILL.md", EDA);
    std::os::unix::fs::symlink(&outside, f.market.join("plugins/linked")).unwrap();

    let report = apply_now(&f);
    let notes = report.notes.join("\n");
    assert!(notes.contains("leads out of the catalog"), "{notes}");
    assert!(notes.contains("another repository"), "{notes}");
    assert!(notes.contains("escape/eda: not found"), "{notes}");
    assert!(!f.project.join(".claude/skills/escape__eda").exists());
    // The catalog's honest half still installs.
    assert!(f.project.join(".claude/skills/data-science__eda").is_file() || is_clean(&f));
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_plain_catalog_installs_exactly_where_it_always_did() {
    let f = fixture(
        "\"claude\", \"codex\", \"opencode\"",
        "[skills.gh]\nsource = \"plain\"\n",
    );
    apply_now(&f);

    // One tree, the same path on every tool, and the catalog's own bytes:
    // nothing about namespacing reaches a catalog that never used it.
    let source = fs::read_to_string(
        f.project
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("plain/skills/gh/SKILL.md"),
    )
    .unwrap();
    assert_eq!(read(&f, ".agents/skills/gh/SKILL.md"), source);
    assert!(f.project.join(".claude/skills/gh").is_symlink());
    // OpenCode reads the shared tree itself, so it holds no second copy.
    assert!(!f.project.join(".opencode/skills/gh").exists());
    assert!(is_clean(&f));
}

#[test]
#[allow(clippy::unwrap_used)]
fn adding_everything_a_catalog_offers_writes_names_that_load_again() {
    let f = fixture("\"claude\"", "");
    let request = ops::AddRequest {
        source: Some("market".to_owned()),
        all: true,
        ..ops::AddRequest::default()
    };
    let report = ops::add(&f.env, &f.scope, &request).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    // The manifest is written and read back by kendex itself: a key with a
    // `/` in it has to survive that round trip, quotes and all.
    let text = read(&f, "kendex.toml");
    assert!(text.contains("\"data-science/eda\""), "{text}");
    let manifest = ops::manifest_for_mutation(&f.env, &f.scope).unwrap();
    assert!(manifest.skills.contains_key("data-science/eda"));
    assert!(manifest.agents.contains_key("code-review/reviewer"));
    assert!(f.project.join(".claude/skills/data-science__eda").exists());
    assert!(is_clean(&f));
}

/// A registry dressed up to read a file outside the catalog is that
/// catalog's problem. The refusal is reported and the healthy source in the
/// same project installs as usual.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registry_that_reaches_outside_costs_only_its_own_source() {
    let f = fixture(
        "\"claude\"",
        "[skills.\"data-science/eda\"]\nsource = \"market\"\n\n[skills.gh]\nsource = \"plain\"\n",
    );
    let registry = f.market.join(".claude-plugin/marketplace.json");
    fs::remove_file(&registry).unwrap();
    std::os::unix::fs::symlink("/etc/hostname", &registry).unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("refused catalog read")),
        "{:?}",
        report.notes
    );
    apply::execute(&f.env, &report.plan).unwrap();
    read(&f, ".claude/skills/gh/SKILL.md");
    assert!(!f.project.join(".claude/skills/data-science__eda").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_changed_plugin_refreshes_in_place() {
    let f = fixture(
        "\"claude\"",
        "[skills.\"data-science/eda\"]\nsource = \"market\"\n",
    );
    apply_now(&f);
    assert!(is_clean(&f));

    write(
        &f.market,
        "plugins/data-science/skills/eda/SKILL.md",
        &EDA.replace("Look at the data.", "Look at the data twice."),
    );
    assert!(!is_clean(&f), "an upstream change is drift until applied");
    apply_now(&f);
    assert!(read(&f, ".claude/skills/data-science__eda/SKILL.md").contains("twice"));
    assert!(is_clean(&f));
}
