//! Consumer policy, native rendering and read-only declared intent through their real owners.
use crate::test_util::{rooted, source_path};
use kendex_core::engine::{AgentModelRequest, agent_model_request};
use kendex_core::env::{Env, FakeOs};
use kendex_core::harness::models::{ModelClass, ModelRequest};
use kendex_core::manifest::{self, Manifest};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use std::collections::BTreeMap;
use std::fs;

#[test]
fn manifest_round_trip_validation_and_policy_hash() {
    let text = "schema = 6\nmodel-classes.fast = \"custom/fast-v2\"\n";
    let parsed = manifest::parse_text(std::path::Path::new("kendex.toml"), text).unwrap();
    let manifest::ManifestFile::Current(parsed) = parsed else {
        panic!("current manifest");
    };
    assert_eq!(parsed.model_classes["fast"], "custom/fast-v2");
    let saved = toml::to_string(&parsed).unwrap();
    let roundtrip = manifest::parse_text(std::path::Path::new("kendex.toml"), &saved).unwrap();
    assert_eq!(roundtrip, manifest::ManifestFile::Current(parsed.clone()));
    let before = kendex_core::hash::relevant_sections(
        &Manifest::default(),
        ItemKind::Agent,
        "worker",
        HarnessId::Claude,
    );
    let after =
        kendex_core::hash::relevant_sections(&parsed, ItemKind::Agent, "worker", HarnessId::Claude);
    assert_ne!(before, after);
    for (key, value) in [
        ("other", "custom/model"),
        ("fast", "inherit"),
        ("fast", "light"),
        ("fast", "bare"),
        ("fast", ""),
        ("fast", "anthropic/claude-haiku-4-5"),
    ] {
        let text = format!("schema = 6\nmodel-classes.{key} = {value:?}\n");
        assert!(
            manifest::parse_text(std::path::Path::new("kendex.toml"), &text).is_err(),
            "{text}"
        );
    }
}
#[test]
fn project_policy_replaces_personal_per_key_without_catalog_input() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let personal_path = manifest::manifest_path(&env, &Scope::Global);
    fs::create_dir_all(personal_path.parent().unwrap()).unwrap();
    fs::write(&personal_path, "schema = 6\nmodel-classes.fast = \"custom/personal\"\nmodel-classes.light = \"custom/light\"\n").unwrap();
    let project = Manifest {
        model_classes: BTreeMap::from([("fast".into(), "custom/project".into())]),
        ..Manifest::default()
    };
    let policy = manifest::model_class_overrides(
        &env,
        &Scope::Project {
            root: home.join("project"),
        },
        &project,
    )
    .unwrap();
    assert_eq!(policy["fast"], "custom/project");
    assert_eq!(policy["light"], "custom/light");
    fs::write(&personal_path, "not a manifest").unwrap();
    assert!(
        manifest::model_class_overrides(
            &env,
            &Scope::Project {
                root: home.join("project")
            },
            &project
        )
        .is_err()
    );
}
#[test]
fn every_native_renderer_keeps_valid_class_representation() {
    use kendex_core::render::agent::{EffectiveAgent, generate, parse_source_agent};
    let scope = Scope::Global;
    for harness in HarnessId::ALL {
        for class in ["top", "standard", "light", "fast"] {
            let source = parse_source_agent(&format!(
                "---\nname: worker\ndescription: Work\nmodel: {class}\n---\nBody.\n"
            ))
            .unwrap();
            let agent = EffectiveAgent {
                source: &source,
                harness,
                scope: &scope,
                skills: vec![],
                overrides: Default::default(),
                model_classes: Default::default(),
                permissions: EffectiveAgent::intent(&source, &Default::default()),
                launch_instructions: None,
                additional_instructions: None,
                custom_hooks: vec![],
            };
            let rendered = generate(&agent).unwrap();
            let findings =
                kendex_core::render::validate::validate_agent(harness, "worker", &rendered.text);
            assert!(
                findings.iter().all(|f| !f.is_breakage()),
                "{harness:?}/{class}: {findings:?}"
            );
            match harness {
                HarnessId::Claude => {
                    let expected = match class {
                        "top" => "fable",
                        "standard" => "opus",
                        "light" | "fast" => "sonnet",
                        _ => unreachable!(),
                    };
                    assert!(
                        rendered.text.contains(&format!("model: {expected}\n")),
                        "{}",
                        rendered.text
                    );
                }
                HarnessId::Pi => assert!(rendered.text.contains(&format!("model: {class}\n"))),
                HarnessId::Codex => assert!(!rendered.text.contains("model =")),
                HarnessId::Copilot
                | HarnessId::Opencode
                | HarnessId::Gemini
                | HarnessId::Antigravity
                | HarnessId::Cursor => {
                    assert!(!rendered.text.contains(&format!("model: {class}")));
                }
            }
        }
    }
    for harness in [
        HarnessId::Claude,
        HarnessId::Codex,
        HarnessId::Copilot,
        HarnessId::Opencode,
        HarnessId::Gemini,
        HarnessId::Antigravity,
    ] {
        let text = match harness {
            HarnessId::Codex => {
                "name = \"worker\"\ndescription = \"Work\"\ndeveloper_instructions = \"Body\"\nmodel = \"fast\"\n"
            }
            _ => "---\nname: worker\ndescription: Work\nmodel: fast\n---\nBody\n",
        };
        let findings = kendex_core::render::validate::validate_agent(harness, "worker", text);
        assert!(
            findings.iter().any(|f| f.is_breakage()),
            "{harness:?}: unsupported canonical class accepted"
        );
    }
}

#[test]
fn declared_intent_uses_source_and_overrides_not_projected_alias() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("project");
    let catalog = home.join("catalog");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/worker.md"),
        "---\nname: worker\ndescription: Work\nmodel: fast\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        catalog.join("kendex.toml"),
        "is_source_catalog = true\n[agent-frontmatter.claude.worker]\nmodel = \"light\"\n",
    )
    .unwrap();
    let consumer = format!(
        "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\n[agents.worker]\nsource = \"cat\"\n[agent-frontmatter.claude.worker]\nmodel = \"fast\"\n",
        source_path(&catalog)
    );
    fs::write(project.join("kendex.toml"), &consumer).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = kendex_core::engine::audit(&env, &scope).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();
    let native = project.join(".claude/agents/worker.md");
    assert!(
        fs::read_to_string(&native)
            .unwrap()
            .contains("model: sonnet\n")
    );
    match agent_model_request(&env, &project, HarnessId::Claude, "worker").unwrap() {
        AgentModelRequest::Managed { request, .. } => assert_eq!(
            request,
            ModelRequest::Class {
                class: ModelClass::Fast
            }
        ),
        AgentModelRequest::Unmanaged => panic!("declared worker became unmanaged"),
    }
    assert!(matches!(
        agent_model_request(&env, &project, HarnessId::Claude, "other").unwrap(),
        AgentModelRequest::Unmanaged
    ));
    fs::write(&native, "edited managed installation").unwrap();
    assert!(
        agent_model_request(&env, &project, HarnessId::Claude, "worker")
            .unwrap_err()
            .contains("edited")
    );
    fs::write(project.join("kendex.toml"), "unreadable").unwrap();
    assert!(agent_model_request(&env, &project, HarnessId::Claude, "other").is_err());
}

#[test]
fn plugin_qualified_declared_names_and_read_failures_stay_distinct() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("project");
    let catalog = home.join("catalog");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(catalog.join(".claude-plugin")).unwrap();
    fs::create_dir_all(catalog.join("plugins/pack/.claude-plugin")).unwrap();
    fs::create_dir_all(catalog.join("plugins/pack/agents")).unwrap();
    fs::write(
        catalog.join(".claude-plugin/marketplace.json"),
        r#"{"name":"fixture","plugins":[{"name":"pack","source":"./plugins/pack"}]}"#,
    )
    .unwrap();
    fs::write(
        catalog.join("plugins/pack/.claude-plugin/plugin.json"),
        r#"{"name":"pack"}"#,
    )
    .unwrap();
    let source_file = catalog.join("plugins/pack/agents/worker.md");
    fs::write(
        &source_file,
        "---\nname: worker\ndescription: Work\nmodel: fast\n---\nBody.\n",
    )
    .unwrap();
    fs::write(project.join("kendex.toml"), format!("schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\n[bundles.pack]\nsource = \"cat\"\n", source_path(&catalog))).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = kendex_core::engine::audit(&env, &scope).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();
    assert!(matches!(
        agent_model_request(&env, &project, HarnessId::Claude, "pack__worker").unwrap(),
        AgentModelRequest::Managed {
            request: ModelRequest::Class {
                class: ModelClass::Fast
            },
            ..
        }
    ));
    fs::remove_file(source_file).unwrap();
    assert!(agent_model_request(&env, &project, HarnessId::Claude, "pack__worker").is_err());
}
