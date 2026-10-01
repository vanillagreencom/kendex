//! Consumer files from the catalog rename reach the real lookup, plan and
//! transactional apply. The must-fail control runs this fixture on main.

use std::fs;
use std::path::PathBuf;

use crate::test_util::{rooted, source_path};
use kendex_core::apply;
use kendex_core::engine::{DeclarationStatus, audit};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};
use kendex_core::source::{find_item, source_config};
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
    let f = fixture("schema = 6");
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
    assert_eq!(
        report.declaration_status,
        DeclarationStatus::Complete,
        "legacy consumer manifest did not render: {:?}",
        report.notes
    );
    assert!(report.refused.is_empty(), "{:?}", report.refused);
    for (old, new) in [("generalist", "maintainer"), ("engineer", "runtime")] {
        let warnings: Vec<_> = report
            .warnings
            .iter()
            .filter(|warning| warning.name == old && warning.harness.is_none())
            .collect();
        assert_eq!(warnings.len(), 1, "{:?}", report.warnings);
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
            "templates/issue.md".to_owned(),
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
                && !warning.message.contains("agents.engineer"))
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_taxonomy_without_an_arriving_skill_still_resolves_legacy_labels() {
    let f = fixture("schema = 6");
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
        let f = fixture(&format!("schema = 6\n{settings}"));
        let before = fs::read(f.project.join("kendex.toml")).unwrap();
        let result = audit(&f.env, &f.scope);
        assert!(
            matches!(
                result,
                Err(kendex_core::error::CoreError::AgentAliasCollision { .. })
            ),
            "{section}: {result:?}"
        );
        assert_eq!(fs::read(f.project.join("kendex.toml")).unwrap(), before);
    }
}
