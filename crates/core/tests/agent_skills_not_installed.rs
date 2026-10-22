//! Agent skill assignments are checked against expanded install declarations.
//! The CLI and desktop expose ItemWarning's machine-read key in report JSON.

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::drift::{copies::CheckMode, report};
use kendex_core::engine::{EngineReport, audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::lock::entry_key;
use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind, Scope};

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

#[allow(clippy::unwrap_used)]
fn assert_assignment_report(f: &Fixture, unresolved: bool, case: &str) {
    let path = manifest::manifest_path(&f.env, &f.scope);
    let lock_path = kendex_core::lock::lock_path(&f.env, &f.scope);
    let before = fs::read(&path).unwrap();
    let lock_before = fs::read(&lock_path).unwrap();
    let checked = report::check(
        &f.env,
        std::slice::from_ref(&f.scope),
        CheckMode::ReportOnly,
    );
    let additions: Vec<_> = checked
        .sections
        .iter()
        .flat_map(|section| &section.lines)
        .filter_map(|line| match &line.remedy {
            Some(report::Remedy::Add {
                kind: ItemKind::Skill,
                name,
                ..
            }) => {
                assert_eq!(line.class, report::Class::Drift, "{case}");
                Some(name.as_str())
            }
            _ => None,
        })
        .collect();
    assert_eq!(
        additions,
        if unresolved { vec!["recon"] } else { vec![] },
        "{case}"
    );
    assert_eq!(
        checked.status,
        if unresolved {
            report::CheckStatus::Drift
        } else {
            report::CheckStatus::Clean
        },
        "{case}"
    );
    assert_eq!(fs::read(path).unwrap(), before, "{case}");
    assert_eq!(fs::read(lock_path).unwrap(), lock_before, "{case}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn agent_assignments_warn_once_per_missing_skill_on_add_and_each_apply() {
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
    let cases = [
        ("[skills.recon]\nsource = \"cat\"\n", "", true, false),
        (
            "[bundles.starter]\nsource = \"cat\"\n",
            "[bundles.starter]\nskills = [\"recon\"]\n",
            false,
            false,
        ),
        ("[skills.parent]\nsource = \"cat\"\n", "", false, false),
        ("", "", false, true),
    ];
    for (declaration, bundle, explicit, unresolved) in cases {
        let f = fixture(
            &format!(
                "[agents.scout]\nsource = \"cat\"\n{declaration}[agent-skills]\nscout = [\"recon\"]\n"
            ),
            &format!("[agent-skills]\nscout = [\"recon\"]\n{bundle}"),
        );
        let report = audit(&f.env, &f.scope).unwrap();
        assert_eq!(!missing(&report).is_empty(), unresolved);
        assert!(report.refused.is_empty());
        apply::execute(&f.env, &report.plan).unwrap();
        assert_eq!(
            !missing(&audit(&f.env, &f.scope).unwrap()).is_empty(),
            unresolved
        );
        let path = manifest::manifest_path(&f.env, &f.scope);
        let declared = manifest::load_for_mutation(&path).unwrap().unwrap();
        assert_eq!(declared.agent_skills["scout"], ["recon"]);
        assert_eq!(declared.skills.contains_key("recon"), explicit);
        assert_assignment_report(&f, unresolved, declaration);
    }
}

#[allow(clippy::unwrap_used)]
fn prepare_assignment_record_case(f: &Fixture, case: &str) -> (PathBuf, PathBuf) {
    let manifest_path = manifest::manifest_path(&f.env, &f.scope);
    let mut declared = manifest::load_for_mutation(&manifest_path)
        .unwrap()
        .unwrap();
    let lock_path = kendex_core::lock::lock_path(&f.env, &f.scope);
    let mut lock = kendex_core::lock::load(&lock_path).unwrap();
    match case {
        "cross-catalog" => {
            let source = declared.sources["cat"].clone();
            declared.sources.insert("other".into(), source);
            declared.skills.get_mut("parent").unwrap().source = "other".into();
            for entry in lock.entries.values_mut() {
                if entry.kind == ItemKind::Skill {
                    entry.source = "other".into();
                    entry.reasons = entry
                        .reasons
                        .iter()
                        .cloned()
                        .map(|mut reason| {
                            if let kendex_core::lock::Reason::RequiredBy { by } = &mut reason {
                                by.source = "other".into();
                            }
                            reason
                        })
                        .collect();
                }
            }
        }
        "disabled skill" => {
            for entry in lock
                .entries
                .values_mut()
                .filter(|entry| entry.name == "recon")
            {
                entry.enabled = false;
            }
        }
        "disabled declaration" => {
            declared
                .skills
                .insert("recon".into(), declared.skills["parent"].clone());
            declared.skills.get_mut("recon").unwrap().enabled = false;
        }
        "removed skill" => declared.suppress(ItemKind::Skill, "recon"),
        "removed parent" => {
            declared.skills.remove("parent");
        }
        "other harness" => {
            lock.entries.retain(|_, entry| {
                entry.name != "recon" || entry.harness == kendex_core::model::HarnessId::Codex
            });
        }
        "wrong parent source" => {
            declared
                .sources
                .insert("other".into(), declared.sources["cat"].clone());
            declared.skills.get_mut("parent").unwrap().source = "other".into();
        }
        "absent lock" | "unreadable lock" | "unreadable manifest" => {}
        _ => unreachable!(),
    }
    fs::write(&manifest_path, toml::to_string(&declared).unwrap()).unwrap();
    kendex_core::lock::save(&lock_path, &lock).unwrap();
    match case {
        "absent lock" => fs::remove_file(&lock_path).unwrap(),
        "unreadable lock" => fs::write(&lock_path, "{").unwrap(),
        "unreadable manifest" => fs::write(&manifest_path, "[").unwrap(),
        _ => {}
    }
    (manifest_path, lock_path)
}

#[test]
#[allow(clippy::unwrap_used)]
fn inherited_assignments_require_skills_on_every_consuming_agent_harness() {
    let scout = "[agents.scout]\nsource = \"cat\"\nharnesses = [\"claude\"]\n";
    let reviewer = "[agents.reviewer-scout]\nsource = \"cat\"\nharnesses = [\"codex\"]\n";
    let claude_reviewer = "[agents.reviewer-scout]\nsource = \"cat\"\nharnesses = [\"claude\"]\n";
    let recorded = "[bundles.reviewers]\nsource = \"cat\"\nharnesses = [\"codex\"]\n";
    for (case, agents, claude_only, exact, unresolved) in [
        (
            "reviewer only",
            "[agents.reviewer-scout]\nsource = \"cat\"\n".to_owned(),
            false,
            false,
            false,
        ),
        (
            "declared reviewer missing",
            format!("{scout}{reviewer}"),
            true,
            false,
            true,
        ),
        (
            "exact override",
            format!("{scout}{reviewer}"),
            true,
            true,
            false,
        ),
        (
            "recorded reviewer only",
            recorded.to_owned(),
            false,
            false,
            false,
        ),
        (
            "recorded reviewer missing",
            format!("{scout}{recorded}"),
            true,
            false,
            true,
        ),
        (
            "declared agents widened by bundle",
            format!("{scout}{claude_reviewer}{recorded}"),
            true,
            false,
            true,
        ),
    ] {
        let harnesses = if claude_only {
            "harnesses = [\"claude\"]\n"
        } else {
            ""
        };
        let assignment = if exact { "reviewer-scout = []\n" } else { "" };
        let f = fixture(
            &format!(
                "{agents}[bundles.starter]\nsource = \"cat\"\n{harnesses}[agent-skills]\nscout = [\"recon\"]\n{assignment}"
            ),
            "[bundles.starter]\nskills = [\"recon\"]\n[bundles.reviewers]\nagents = [\"scout\", \"reviewer-scout\"]\n",
        );
        fs::write(
            f.source.join("agents/reviewer-scout.md"),
            AGENT.replacen("name: scout", "name: reviewer-scout", 1),
        )
        .unwrap();
        let planned = audit(&f.env, &f.scope).unwrap();
        assert!(planned.refused.is_empty(), "{case}");
        apply::execute(&f.env, &planned.plan).unwrap();
        let path = manifest::manifest_path(&f.env, &f.scope);
        let lock_path = kendex_core::lock::lock_path(&f.env, &f.scope);
        let declared = manifest::load_for_mutation(&path).unwrap().unwrap();
        assert_eq!(declared.agent_skills["scout"], ["recon"], "{case}");
        assert!(!declared.skills.contains_key("recon"), "{case}");
        let lock = kendex_core::lock::load(&lock_path).unwrap();
        let reviewer_key = entry_key(ItemKind::Agent, "reviewer-scout", HarnessId::Codex);
        let skill_key = entry_key(ItemKind::Skill, "recon", HarnessId::Codex);
        assert!(lock.entries.contains_key(&reviewer_key), "{case}");
        assert_eq!(
            lock.entries
                .contains_key(&entry_key(ItemKind::Agent, "scout", HarnessId::Codex)),
            agents.contains(recorded),
            "{case}"
        );
        assert_eq!(
            lock.entries.contains_key(&skill_key),
            !claude_only,
            "{case}"
        );
        assert_assignment_report(&f, unresolved, case);
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn check_assignments_require_selected_records_on_each_agent_harness() {
    for (case, unresolved, unknown) in [
        ("cross-catalog", false, false),
        ("disabled skill", true, false),
        ("disabled declaration", false, false),
        ("removed skill", true, false),
        ("removed parent", true, false),
        ("other harness", true, false),
        ("wrong parent source", true, false),
        ("absent lock", true, false),
        ("unreadable lock", false, true),
        ("unreadable manifest", false, true),
    ] {
        let f = fixture(
            "[agents.scout]\nsource = \"cat\"\n[skills.parent]\nsource = \"cat\"\n[agent-skills]\nscout = [\"recon\"]\n",
            "",
        );
        let installed = audit(&f.env, &f.scope).unwrap();
        apply::execute(&f.env, &installed.plan).unwrap();
        let (manifest_path, lock_path) = prepare_assignment_record_case(&f, case);
        let manifest_before = fs::read(&manifest_path).unwrap();
        let lock_before = fs::read(&lock_path).ok();
        let checked = report::check(&f.env, &[f.scope.clone()], CheckMode::ReportOnly);
        let lines: Vec<_> = checked
            .sections
            .iter()
            .flat_map(|section| &section.lines)
            .collect();
        assert_eq!(lines.iter().any(|line| matches!(&line.remedy, Some(report::Remedy::Add { kind: ItemKind::Skill, name, .. }) if name == "recon")), unresolved, "{case}");
        assert_eq!(
            lines
                .iter()
                .any(|line| line.class == report::Class::Unknown),
            unknown,
            "{case}"
        );
        if unresolved || unknown {
            assert_ne!(checked.status, report::CheckStatus::Clean, "{case}");
        }
        assert!(lines.iter().all(|line| !matches!(&line.remedy, Some(report::Remedy::Add { kind: ItemKind::Skill, name, .. }) if name == "recon") || line.class == report::Class::Drift), "{case}");
        assert_eq!(fs::read(manifest_path).unwrap(), manifest_before, "{case}");
        assert_eq!(fs::read(lock_path).ok(), lock_before, "{case}");
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_recorded_agent_fork_still_refuses_an_unresolved_assignment() {
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
