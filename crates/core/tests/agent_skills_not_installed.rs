//! Agent skill assignments are checked against expanded install declarations.
//! The CLI and desktop expose ItemWarning's machine-read key in report JSON.

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{EngineReport, audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::manifest;
use kendex_core::model::{ItemKind, Scope};

use crate::test_util::{rooted, source_path};

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    source: PathBuf,
}

const AGENT: &str = "---\nname: scout\ndescription: Finds things\nmodel: inherit\n---\nBody.\n";

#[allow(clippy::unwrap_used)]
fn fixture(body: &str, catalog: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let source = home.join("catalog");
    fs::create_dir_all(source.join("agents")).unwrap();
    fs::write(source.join("agents/scout.md"), AGENT).unwrap();
    for name in ["recon", "parent"] {
        fs::create_dir_all(source.join(format!("skills/{name}"))).unwrap();
        let dependencies = if name == "parent" {
            "dependencies:\n  required: [recon]\n"
        } else {
            ""
        };
        fs::write(
            source.join(format!("skills/{name}/SKILL.md")),
            format!("---\nname: {name}\ndescription: {name}\n{dependencies}---\nBody.\n"),
        )
        .unwrap();
    }
    fs::write(source.join("kendex.toml"), catalog).unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Project {
        root: home.join("consumer"),
    };
    let path = manifest::manifest_path(&env, &scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        path,
        format!(
            "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\", \"codex\", \"copilot\", \"pi\"]\nmethod = \"copy\"\n{body}",
            source_path(&source)
        ),
    )
    .unwrap();
    Fixture {
        _tmp: tmp,
        env,
        scope,
        source,
    }
}

fn missing(report: &EngineReport) -> Vec<&str> {
    report
        .warnings
        .iter()
        .filter_map(|warning| {
            let line = warning.message.lines().next()?;
            let skill =
                line.strip_prefix("kendex-agent-skill-not-installed: agent=scout skill=")?;
            assert_eq!(warning.kind, ItemKind::Agent);
            assert_eq!(warning.name, "scout");
            assert_eq!(warning.harness, None);
            assert!(warning.remediation.is_some());
            Some(skill)
        })
        .collect()
}

#[test]
#[allow(clippy::unwrap_used)]
fn agent_assignments_warn_once_per_missing_skill_on_add_and_each_apply() {
    crate::diagnostic::parent!(agent_assignments_warn_once_per_missing_skill_on_add_and_each_apply);
    let cases = [
        ("", "[agent-skills]\nscout = [\"recon\"]\n", vec!["recon"]),
        (
            "[agent-skills]\nscout = [\"recon\", \"ghost\", \"ghost\"]\n",
            "",
            vec!["ghost", "recon"],
        ),
    ];
    for (body, catalog, expected) in cases {
        let f = fixture(body, catalog);
        let added = ops::add(
            &f.env,
            &f.scope,
            &ops::AddRequest {
                source: Some("cat".into()),
                agents: vec!["scout".into()],
                no_auto_skills: true,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(missing(&added), expected);
        assert!(added.refused.is_empty());
        apply::execute(&f.env, &added.plan).unwrap();
        assert!(
            manifest::load_for_mutation(&manifest::manifest_path(&f.env, &f.scope))
                .unwrap()
                .unwrap()
                .skills
                .is_empty()
        );
        let Scope::Project { root } = &f.scope else {
            unreachable!();
        };
        for file in [
            ".claude/agents/scout.md",
            ".codex/agents/scout.toml",
            ".github/agents/scout.agent.md",
            ".pi/agents/scout.md",
        ] {
            let rendered = fs::read_to_string(root.join(file)).unwrap();
            assert!(rendered.contains("recon"), "{file}");
            assert!(!rendered.contains("ghost"), "{file}");
        }
        let reapplied = audit(&f.env, &f.scope).unwrap();
        assert_eq!(missing(&reapplied), expected);
        apply::execute(&f.env, &reapplied.plan).unwrap();
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn explicit_bundle_and_dependency_skill_declarations_satisfy_agent_assignments() {
    crate::diagnostic::parent!(
        explicit_bundle_and_dependency_skill_declarations_satisfy_agent_assignments
    );
    let cases = [
        ("[skills.recon]\nsource = \"cat\"\n", ""),
        (
            "[bundles.starter]\nsource = \"cat\"\n",
            "[bundles.starter]\nskills = [\"recon\"]\n",
        ),
        ("[skills.parent]\nsource = \"cat\"\n", ""),
    ];
    for (declaration, bundle) in cases {
        let f = fixture(
            &format!("[agents.scout]\nsource = \"cat\"\n{declaration}"),
            &format!("[agent-skills]\nscout = [\"recon\"]\n{bundle}"),
        );
        let report = audit(&f.env, &f.scope).unwrap();
        assert!(missing(&report).is_empty());
        assert!(report.refused.is_empty());
        apply::execute(&f.env, &report.plan).unwrap();
        assert!(missing(&audit(&f.env, &f.scope).unwrap()).is_empty());
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_recorded_agent_fork_still_refuses_an_unresolved_assignment() {
    crate::diagnostic::parent!(a_recorded_agent_fork_still_refuses_an_unresolved_assignment);
    let f = fixture(
        "[agents.scout]\nsource = \"local\"\n[agent-skills]\nscout = [\"ghost\"]\n[forks.agent.scout]\nsource = \"cat\"\nforked-at = \"2026-10-11T00:00:00Z\"\n",
        "",
    );
    let Scope::Project { root } = &f.scope else {
        unreachable!();
    };
    let local = root.join(".kendex-local/agents");
    fs::create_dir_all(&local).unwrap();
    fs::copy(f.source.join("agents/scout.md"), local.join("scout.md")).unwrap();
    let path = manifest::manifest_path(&f.env, &f.scope);
    let before = fs::read(&path).unwrap();
    assert!(matches!(
        audit(&f.env, &f.scope),
        Err(CoreError::AgentSkillUnavailable { name, skill })
            if name == "scout" && skill == "ghost"
    ));
    assert_eq!(fs::read(path).unwrap(), before);
    assert!(!root.join(".claude/agents/scout.md").exists());
}
