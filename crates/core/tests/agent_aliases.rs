//! Consumer files from the catalog rename reach the real lookup, plan and
//! transactional apply. The must-fail control runs this fixture on main.

use std::fs;
use std::path::{Path, PathBuf};

use crate::test_util::{rooted, source_path};
use kendex_core::apply;
use kendex_core::engine::{DeclarationStatus, EngineReport, adopt, audit, desired::native_dir};
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest::HookAgents;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::source::{find_item, local_source_root, source_config, source_config_for};
use kendex_core::source_read::SealedSource;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture(consumer: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("project");
    let source = home.join("catalog");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(source.join("agents")).unwrap();
    fs::create_dir_all(source.join("skills/review/templates")).unwrap();
    fs::write(
        source.join("kendex.toml"),
        "is_source_catalog = true\n[agent-skills]\nmaintainer = []\nruntime = []\n",
    )
    .unwrap();
    for name in ["maintainer", "runtime"] {
        fs::write(
            source.join("agents").join(format!("{name}.md")),
            format!(
                "---\nname: {name}\ndescription: Change consumer code\nrole: engineer\n---\nBody.\n"
            ),
        )
        .unwrap();
    }
    fs::write(
        source.join("skills/review/SKILL.md"),
        "---\nname: review\ndescription: Review changes\n---\nBody.\n",
    )
    .unwrap();
    fs::write(source.join("skills/review/templates/issue.md"), "Labels: agent:generalist, agent:engineer.\nKeep agent:engineer-extra and otheragent:generalist.\n").unwrap();
    fs::write(
        source.join("skills/review/kendex.settings.toml.example"),
        "[env]\nLINEAR_AGENT_LABELS = \"agent:generalist,agent:engineer\"\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!("{consumer}\n[sources.cat]\n{}\n", source_path(&source)),
    )
    .unwrap();
    Fixture {
        _tmp: tmp,
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        source,
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn lookup_reads_old_names_through_the_catalog_resolver() {
    let f = fixture("schema = 7");
    let sealed = SealedSource::open(&f.source).unwrap();
    let config = source_config(&sealed, "cat").unwrap();
    for (old, new) in [("generalist", "maintainer"), ("engineer", "runtime")] {
        assert_eq!(
            find_item(&sealed, &config, ItemKind::Agent, old),
            Some(f.source.join("agents").join(format!("{new}.md")))
        );
        assert_eq!(
            find_item(&sealed, &config, ItemKind::Agent, new),
            Some(f.source.join("agents").join(format!("{new}.md")))
        );
        assert_eq!(find_item(&sealed, &config, ItemKind::Skill, old), None);
    }
    assert_eq!(
        find_item(&sealed, &config, ItemKind::Agent, "engineer-extra"),
        None
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_legacy_consumer_renders_with_skills_labels_templates_and_one_warning_per_name() {
    let f = fixture(include_str!("fixtures/agent_aliases.toml"));
    fs::write(f.project.join("kendex.settings.toml"), "# consumer settings\n[env]\nKEEP = 'untouched' # consumer\nLINEAR_AGENT_LABELS = 'agent:generalist,agent:engineer,agent:rust' # taxonomy\n").unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    assert_eq!(report.declaration_status, DeclarationStatus::Complete);
    assert!(report.refused.is_empty());
    for (old, new) in [("generalist", "maintainer"), ("engineer", "runtime")] {
        let warnings: Vec<_> = report
            .warnings
            .iter()
            .filter(|warning| warning.name == old && warning.harness.is_none())
            .collect();
        assert_eq!(warnings.len(), 1);
        let warning = warnings[0];
        assert!(warning.message.contains(new));
        for setting in [
            format!("agents.{old}"),
            format!("agent-skills.{old}"),
            format!("agent-additional-instructions.{old}"),
            format!("agent-launch-instructions.{old}"),
            format!("agent-frontmatter.pi.{old}"),
            "skill-instructions.review".to_owned(),
            "env.LINEAR_AGENT_LABELS".to_owned(),
            Path::new("templates")
                .join("issue.md")
                .display()
                .to_string(),
            "kendex.settings.toml.example".to_owned(),
        ] {
            assert!(
                warning.message.contains(&setting),
                "missing {setting}: {warning:?}"
            );
        }
    }
    apply::execute(&f.env, &report.plan).unwrap();
    for (name, instructions) in [
        ("maintainer", "Consumer maintainer instructions."),
        ("runtime", "Consumer runtime instructions."),
    ] {
        let agent = fs::read_to_string(f.project.join(".claude/agents").join(format!("{name}.md")))
            .unwrap();
        assert!(
            agent.lines().any(|line| line == "skills: review"),
            "{agent}"
        );
        assert!(agent.contains(instructions), "{agent}");
    }
    let template =
        fs::read_to_string(f.project.join(".claude/skills/review/templates/issue.md")).unwrap();
    assert_eq!(
        template,
        "Labels: agent:maintainer, agent:runtime.\nKeep agent:engineer-extra and otheragent:generalist.\n"
    );
    let settings = fs::read_to_string(f.project.join("kendex.settings.toml")).unwrap();
    assert_eq!(
        settings,
        "# consumer settings\n[env]\nKEEP = 'untouched' # consumer\nLINEAR_AGENT_LABELS = \"agent:maintainer,agent:runtime,agent:rust\" # taxonomy\n"
    );
    let manifest = kendex_core::manifest::load_for_mutation(&f.project.join("kendex.toml"))
        .unwrap()
        .unwrap();
    assert!(manifest.agents.contains_key("maintainer"));
    assert!(manifest.agents.contains_key("runtime"));
    assert_custom_hooks(&f, &manifest, &report);
    for (name, allowed, launch) in [
        ("maintainer", "runtime", "Launch agent:runtime."),
        ("runtime", "maintainer", "Launch agent:maintainer."),
    ] {
        assert_eq!(manifest.agent_skills[name], ["review"]);
        assert_eq!(manifest.agent_launch_instructions[name], launch);
        assert_eq!(
            manifest.agent_frontmatter["pi"][name]
                .allowed_subagents
                .as_deref(),
            Some([allowed.to_owned()].as_slice())
        );
    }
    let after = audit(&f.env, &f.scope).unwrap();
    assert_eq!(after.declaration_status, DeclarationStatus::Complete);
    assert!(
        after
            .warnings
            .iter()
            .filter(|warning| ["generalist", "engineer"].contains(&warning.name.as_str()))
            .all(|warning| !warning.message.contains("agents.generalist")
                && !warning.message.contains("agents.engineer")
                && !warning.message.contains("custom-hooks"))
    );
}

#[allow(clippy::unwrap_used)]
fn assert_custom_hooks(
    f: &Fixture,
    manifest: &kendex_core::manifest::Manifest,
    report: &EngineReport,
) {
    let cases = [
        (
            "scalar",
            HookAgents::One("maintainer".into()),
            &["maintainer"][..],
            true,
        ),
        (
            "list",
            HookAgents::Many(vec!["maintainer".into(), "reviewer".into(), "all".into()]),
            &["maintainer"][..],
            true,
        ),
        (
            "role",
            HookAgents::One("engineer".into()),
            &["maintainer", "runtime"][..],
            false,
        ),
        (
            "role-list",
            HookAgents::Many(vec!["engineer".into()]),
            &["maintainer", "runtime"][..],
            false,
        ),
        ("everyone", HookAgents::One("all".into()), &[][..], false),
    ];
    assert_eq!(manifest.custom_hooks.len(), cases.len());
    for (index, (name, selector, recipients, renamed)) in cases.into_iter().enumerate() {
        assert_eq!(manifest.custom_hooks[index].agents, selector, "{name}");
        for old in ["generalist", "engineer"] {
            let warning = report
                .warnings
                .iter()
                .find(|warning| warning.name == old && warning.harness.is_none())
                .unwrap();
            let setting = format!("custom-hooks[{index}].agents");
            assert_eq!(
                warning.message.contains(&setting),
                old == "generalist" && renamed,
                "{setting}: {warning:?}"
            );
        }
        for agent_name in ["maintainer", "runtime"] {
            let agent = fs::read_to_string(
                f.project
                    .join(".claude/agents")
                    .join(format!("{agent_name}.md")),
            )
            .unwrap();
            assert_eq!(
                agent.contains(&format!("command: \"./{name}.sh\"")),
                recipients.contains(&agent_name),
                "{name} on {agent_name}: {agent}"
            );
        }
    }
    let hook_registry: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(f.project.join(".claude/settings.json")).unwrap())
            .unwrap();
    assert_eq!(
        hook_registry["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
        "./everyone.sh"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_taxonomy_without_an_arriving_skill_still_resolves_legacy_labels() {
    let f = fixture("schema = 7");
    fs::write(
        f.project.join("kendex.settings.toml"),
        "[env]\nLINEAR_AGENT_LABELS = \"agent:generalist,agent:engineer\"\n",
    )
    .unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    assert_eq!(report.warnings.len(), 2);
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(
        fs::read_to_string(f.project.join("kendex.settings.toml")).unwrap(),
        "[env]\nLINEAR_AGENT_LABELS = \"agent:maintainer,agent:runtime\"\n"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn two_settings_for_one_agent_are_refused_before_writes() {
    for (section, settings) in [
        (
            "agents",
            "[agents.generalist]\nsource = 'cat'\n[agents.maintainer]\nsource = 'cat'\n",
        ),
        (
            "agent-skills",
            "[agent-skills]\ngeneralist = ['review']\nmaintainer = []\n",
        ),
        (
            "agent-additional-instructions",
            "[agent-additional-instructions]\ngeneralist = 'old'\nmaintainer = 'new'\n",
        ),
    ] {
        let f = fixture(&format!("schema = 7\n{settings}"));
        let before = fs::read(f.project.join("kendex.toml")).unwrap();
        let result = audit(&f.env, &f.scope);
        assert!(
            matches!(
                result,
                Err(kendex_core::error::CoreError::AgentAliasCollision { .. })
            ),
            "{section}"
        );
        assert_eq!(fs::read(f.project.join("kendex.toml")).unwrap(), before);
    }
}

#[derive(Clone, Copy, Debug)]
enum LocalOrigin {
    Fork,
    Adopt,
}

/// Fork stores the edited agent under its installed name. The fixture pins
/// its captured declaration and provenance; adoption runs the capture producer.
#[test]
#[allow(clippy::unwrap_used)]
fn local_forks_and_adoptions_keep_their_names_and_customizations() {
    for origin in [LocalOrigin::Fork, LocalOrigin::Adopt] {
        let f = fixture(include_str!("fixtures/agent_aliases_local.toml"));
        for scope in [Scope::Global, f.scope.clone()] {
            let path = kendex_core::manifest::manifest_path(&f.env, &scope);
            let before = capture_local_agents(&f, &scope, origin);
            let local = local_source_root(&f.env, &scope);
            let captured: Vec<_> = ["generalist", "engineer"]
                .map(|name| fs::read(local.join("agents").join(format!("{name}.md"))).unwrap())
                .into();
            if let Scope::Project { root } = &scope {
                fs::write(
                    root.join("kendex.settings.toml"),
                    "[env]\nLINEAR_AGENT_LABELS = 'agent:generalist,agent:engineer'\n",
                )
                .unwrap();
            }
            let report = audit(&f.env, &scope).unwrap();
            assert_eq!(
                report.declaration_status,
                DeclarationStatus::Complete,
                "local identity lost for {origin:?} in {scope:?}"
            );
            assert!(report.refused.is_empty());
            assert!(
                report
                    .warnings
                    .iter()
                    .all(|warning| warning.harness.is_some()
                        || !["generalist", "engineer"].contains(&warning.name.as_str()))
            );
            apply::execute(&f.env, &report.plan).unwrap();
            let after = kendex_core::manifest::load_for_mutation(&path)
                .unwrap()
                .unwrap();
            assert_eq!(after, before, "{origin:?} in {scope:?}");
            assert_local_renderings(&f.env, &scope, &local, &captured);
            if let Scope::Project { root } = &scope {
                assert_eq!(
                    fs::read_to_string(root.join("kendex.settings.toml")).unwrap(),
                    "[env]\nLINEAR_AGENT_LABELS = 'agent:generalist,agent:engineer'\n"
                );
                assert_eq!(
                    fs::read_to_string(root.join(".claude/skills/review/templates/issue.md"))
                        .unwrap(),
                    fs::read_to_string(f.source.join("skills/review/templates/issue.md")).unwrap()
                );
            }
            let settled = audit(&f.env, &scope).unwrap();
            assert_eq!(settled.declaration_status, DeclarationStatus::Complete);
            assert!(settled.drift.is_empty());
        }
    }
}

#[allow(clippy::unwrap_used)]
fn capture_local_agents(
    f: &Fixture,
    scope: &Scope,
    origin: LocalOrigin,
) -> kendex_core::manifest::Manifest {
    let path = kendex_core::manifest::manifest_path(&f.env, scope);
    let mut manifest = kendex_core::manifest::load_for_mutation(&f.project.join("kendex.toml"))
        .unwrap()
        .unwrap();
    if matches!(origin, LocalOrigin::Adopt) {
        manifest.forks.clear();
    }
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, toml::to_string(&manifest).unwrap()).unwrap();
    let local = local_source_root(&f.env, scope);
    let agents = native_dir(&f.env, scope, HarnessId::Claude, ItemKind::Agent).unwrap();
    for name in ["generalist", "engineer"] {
        let content =
            format!("---\nname: {name}\ndescription: Local agent\n---\nMy {name} body.\n");
        match origin {
            LocalOrigin::Fork => {
                fs::create_dir_all(local.join("agents")).unwrap();
                fs::write(local.join("agents").join(format!("{name}.md")), &content).unwrap();
            }
            LocalOrigin::Adopt => {
                fs::create_dir_all(&agents).unwrap();
                fs::write(agents.join(format!("{name}.md")), &content).unwrap();
                let plan = adopt::adopt(&f.env, scope, ItemKind::Agent, name, &[HarnessId::Claude])
                    .unwrap();
                apply::execute(&f.env, &plan).unwrap();
            }
        }
    }
    manifest
}

#[allow(clippy::unwrap_used)]
fn assert_local_renderings(
    env: &Env,
    scope: &Scope,
    local: &std::path::Path,
    captured: &[Vec<u8>],
) {
    let sealed = SealedSource::open(local).unwrap();
    let config = source_config_for(&sealed, "local").unwrap();
    let agents = native_dir(env, scope, HarnessId::Claude, ItemKind::Agent).unwrap();
    for (index, (name, canonical, peer)) in [
        ("generalist", "maintainer", "engineer"),
        ("engineer", "runtime", "generalist"),
    ]
    .into_iter()
    .enumerate()
    {
        let file = local.join("agents").join(format!("{name}.md"));
        assert_eq!(
            find_item(&sealed, &config, ItemKind::Agent, name),
            Some(file.clone())
        );
        assert_eq!(fs::read(&file).unwrap(), captured[index]);
        assert!(
            !local
                .join("agents")
                .join(format!("{canonical}.md"))
                .exists()
        );
        let agent = fs::read_to_string(agents.join(format!("{name}.md"))).unwrap();
        for expected in [
            format!("name: {name}"),
            format!("My {name} body."),
            format!("Local {name} instructions: agent:{peer}."),
            format!("Launch agent:{peer}."),
            "skills: review".to_owned(),
        ] {
            assert!(agent.contains(&expected), "missing {expected}: {agent}");
        }
        assert_eq!(
            agent.contains("./local.sh"),
            name == "generalist",
            "{agent}"
        );
        assert!(
            fs::read_to_string(agents.join(format!("{canonical}.md")))
                .unwrap()
                .contains("Body.")
        );
    }
}
