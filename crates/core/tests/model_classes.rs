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
fn native_bindings_select_only_the_requested_harness_and_class() {
    use kendex_core::harness::models::{ResolutionContext, resolve_model};
    use kendex_core::render::agent::{EffectiveAgent, generate, parse_source_agent};
    let scope = Scope::Global;
    let source =
        parse_source_agent("---\nname: worker\ndescription: Work\nmodel: standard\n---\nBody.\n")
            .unwrap();
    for harness in HarnessId::ALL {
        let mut agent = EffectiveAgent {
            source: &source,
            harness,
            scope: &scope,
            skills: vec![],
            overrides: Default::default(),
            model_classes: Default::default(),
            model_bindings: Default::default(),
            permissions: EffectiveAgent::intent(&source, &Default::default()),
            launch_instructions: None,
            additional_instructions: None,
            custom_hooks: vec![],
            role_policy: None,
        };
        let unbound = generate(&agent).unwrap().text;
        let other_harness = if harness == HarnessId::Codex {
            "copilot"
        } else {
            "codex"
        };
        agent.model_bindings = BTreeMap::from([(
            other_harness.into(),
            BTreeMap::from([("standard".into(), "gpt-6.1-sol".into())]),
        )]);
        assert_eq!(
            generate(&agent).unwrap().text,
            unbound,
            "another harness's binding"
        );
        for (class, selector, changes) in [
            ("light", "gpt-6.1-luna", false),
            (
                "standard",
                "gpt-6.1-sol",
                matches!(harness, HarnessId::Codex | HarnessId::Copilot),
            ),
        ] {
            agent.model_bindings = BTreeMap::from([(
                harness.name().into(),
                BTreeMap::from([(class.into(), selector.into())]),
            )]);
            let rendered = generate(&agent).unwrap();
            if changes {
                match harness {
                    HarnessId::Codex => assert_eq!(
                        rendered.text.parse::<toml::Table>().unwrap()["model"].as_str(),
                        Some(selector)
                    ),
                    HarnessId::Copilot => assert_eq!(
                        parse_source_agent(&rendered.text).unwrap().model.as_str(),
                        selector
                    ),
                    _ => unreachable!(),
                }
                let resolved = resolve_model(
                    &ModelRequest::Class {
                        class: ModelClass::Standard,
                    },
                    ResolutionContext::Render(harness, &agent.model_bindings),
                    &agent.model_classes,
                );
                assert!(resolved.diagnostics().is_empty());
            } else {
                assert_eq!(rendered.text, unbound, "{harness:?}/{class}");
            }
        }
        if harness == HarnessId::Codex {
            agent.overrides.model = Some("gpt-6-astra".into());
            let rendered = generate(&agent).unwrap();
            assert_eq!(
                rendered.text.parse::<toml::Table>().unwrap()["model"].as_str(),
                Some("gpt-6-astra")
            );
        }
    }
}

#[test]
fn binding_validation_names_each_rejected_location() {
    for (text, location) in [
        ("model-bindings = 1", "model-bindings"),
        ("model-bindings.codex = 1", "model-bindings.codex"),
        (
            "model-bindings.claude.standard = 'opus'",
            "model-bindings.claude",
        ),
        (
            "model-bindings.pi.standard = 'openai/sol'",
            "model-bindings.pi",
        ),
        (
            "model-bindings.cursor.standard = 'sol'",
            "model-bindings.cursor",
        ),
        (
            "model-bindings.opencode.standard = 'sol'",
            "model-bindings.opencode",
        ),
        (
            "model-bindings.gemini.standard = 'sol'",
            "model-bindings.gemini",
        ),
        (
            "model-bindings.antigravity.standard = 'sol'",
            "model-bindings.antigravity",
        ),
        (
            "model-bindings.other.standard = 'sol'",
            "model-bindings.other",
        ),
        (
            "model-bindings.codex.opus = 'sol'",
            "model-bindings.codex.opus",
        ),
        (
            "model-bindings.codex.standard = ''",
            "model-bindings.codex.standard",
        ),
        (
            "model-bindings.codex.standard = ' sol'",
            "model-bindings.codex.standard",
        ),
        (
            "model-bindings.codex.standard = 's ol'",
            "model-bindings.codex.standard",
        ),
        (
            "model-bindings.codex.standard = 1",
            "model-bindings.codex.standard",
        ),
    ] {
        let error = manifest::parse_text(
            std::path::Path::new("kendex.toml"),
            &format!("schema = 6\n{text}\n"),
        )
        .unwrap_err();
        let kendex_core::error::CoreError::ManifestInvalid { findings, .. } = error else {
            panic!("wrong refusal kind")
        };
        assert!(
            findings.iter().any(|finding| finding.location == location),
            "{location}"
        );
    }
}

#[test]
fn bindings_merge_round_trip_and_hash_only_their_harness() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let path = manifest::manifest_path(&env, &Scope::Global);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, "schema = 6\n[model-bindings.codex]\nstandard = 'gpt-6-sol'\nlight = 'gpt-6.1-luna'\n[model-bindings.copilot]\nstandard = 'claude-opus-4.6'\n").unwrap();
    let project_root = home.join("project");
    let catalog = home.join("catalog");
    fs::create_dir_all(&project_root).unwrap();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("agents/worker.md"),
        "---\nname: worker\ndescription: Work\nmodel: standard\n---\nBody.\n",
    )
    .unwrap();
    let manifest::ManifestFile::Current(mut project) = manifest::parse_text(
        std::path::Path::new("kendex.toml"),
        &format!("schema = 6\nmodel-bindings.codex.standard = 'gpt-6.1-sol'\n[sources.cat]\n{}\n[install]\nharnesses = ['codex', 'copilot']\nmethod = 'copy'\n[agents.worker]\nsource = 'cat'\n", source_path(&catalog)),
    )
    .unwrap() else {
        panic!("current manifest")
    };
    let saved = toml::to_string(&project).unwrap();
    assert_eq!(
        manifest::parse_text(std::path::Path::new("kendex.toml"), &saved).unwrap(),
        manifest::ManifestFile::Current(project.clone())
    );
    let policy = manifest::model_bindings(
        &env,
        &Scope::Project {
            root: home.join("project"),
        },
        &project,
    )
    .unwrap();
    assert_eq!(policy["codex"]["standard"], "gpt-6.1-sol");
    assert_eq!(policy["codex"]["light"], "gpt-6.1-luna");
    assert_eq!(policy["copilot"]["standard"], "claude-opus-4.6");
    let before = project.clone();
    project
        .model_bindings
        .get_mut("codex")
        .unwrap()
        .insert("standard".into(), "gpt-6-astra".into());
    for harness in HarnessId::ALL {
        let old = kendex_core::hash::relevant_sections(&before, ItemKind::Agent, "worker", harness);
        let new =
            kendex_core::hash::relevant_sections(&project, ItemKind::Agent, "worker", harness);
        assert_eq!(old != new, harness == HarnessId::Codex, "{harness:?}");
    }
    assert_binding_hashes_after_apply(&env, &project_root, (*project).clone()).unwrap();
    fs::write(&path, "not a manifest").unwrap();
    assert!(
        manifest::model_bindings(
            &env,
            &Scope::Project {
                root: home.join("project")
            },
            &project
        )
        .is_err()
    );
}

fn assert_binding_hashes_after_apply(
    env: &Env,
    root: &std::path::Path,
    mut project: Manifest,
) -> Result<(), Box<dyn std::error::Error>> {
    let project_path = root.join("kendex.toml");
    let personal_path = manifest::manifest_path(env, &Scope::Global);
    let mut personal = manifest::load_current(&personal_path)?.ok_or("missing personal fixture")?;
    fs::write(&project_path, toml::to_string(&project)?)?;
    let mut before = installed_binding_records(env, root)?;
    // A nonrequested class still changes customization identity, without changing bytes.
    for (personal_edit, harness, class, selector, changes_bytes) in [
        (false, HarnessId::Codex, "light", "gpt-6.1-luna-v2", false),
        (false, HarnessId::Codex, "standard", "gpt-6.1-sol", true),
        (true, HarnessId::Copilot, "light", "claude-haiku-4.5", false),
        (
            true,
            HarnessId::Copilot,
            "standard",
            "claude-opus-4.5",
            true,
        ),
    ] {
        let (policy, path) = if personal_edit {
            (&mut personal, &personal_path)
        } else {
            (&mut project, &project_path)
        };
        policy
            .model_bindings
            .entry(harness.name().into())
            .or_default()
            .insert(class.into(), selector.into());
        fs::write(path, toml::to_string(policy)?)?;
        let after = installed_binding_records(env, root)?;
        for installed in [HarnessId::Codex, HarnessId::Copilot] {
            let (old_hash, old_bytes) = &before[&installed];
            let (new_hash, new_bytes) = &after[&installed];
            assert_eq!(
                old_hash != new_hash,
                installed == harness,
                "personal={personal_edit} {harness:?}/{class}: {installed:?} recorded hash"
            );
            assert_eq!(
                old_bytes != new_bytes,
                installed == harness && changes_bytes,
                "personal={personal_edit} {harness:?}/{class}: {installed:?} bytes"
            );
        }
        before = after;
    }
    Ok(())
}

type BindingRecords = BTreeMap<HarnessId, (String, Vec<u8>)>;

fn installed_binding_records(
    env: &Env,
    root: &std::path::Path,
) -> Result<BindingRecords, Box<dyn std::error::Error>> {
    let scope = Scope::Project { root: root.into() };
    let report = kendex_core::engine::audit(env, &scope)?;
    assert!(report.refused.is_empty(), "{:?}", report.refused);
    kendex_core::apply::execute(env, &report.plan)?;
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(env, &scope))?;
    [
        (HarnessId::Codex, ".codex/agents/worker.toml"),
        (HarnessId::Copilot, ".github/agents/worker.agent.md"),
    ]
    .map(|(harness, path)| {
        let key = kendex_core::lock::entry_key(ItemKind::Agent, "worker", harness);
        Ok((
            harness,
            (
                lock.entries[&key].source_hash.clone(),
                fs::read(root.join(path))?,
            ),
        ))
    })
    .into_iter()
    .collect()
}

#[test]
fn plan_readback_refuses_provider_qualified_codex_binding() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("project");
    let catalog = home.join("catalog");
    fs::create_dir_all(&project).unwrap();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("agents/worker.md"),
        "---\nname: worker\ndescription: Work\nmodel: standard\n---\nBody.\n",
    )
    .unwrap();
    fs::write(project.join("kendex.toml"), format!("schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = ['codex']\n[agents.worker]\nsource = 'cat'\n[model-bindings.codex]\nstandard = 'openai/gpt-6.1-sol'\n", source_path(&catalog))).unwrap();
    let report = kendex_core::engine::audit(
        &env,
        &Scope::Project {
            root: project.clone(),
        },
    )
    .unwrap();
    assert!(report.refused.iter().any(|row| row.name == "worker"
        && row.harness == HarnessId::Codex
        && row.refusal == kendex_core::engine::desired::RefusalKind::Render));
    assert!(!project.join(".codex/agents/worker.toml").exists());
    fs::create_dir_all(project.join(".github")).unwrap();
    fs::write(project.join(".github/allowed_models.txt"), "gpt-6.1-sol\n").unwrap();
    fs::write(project.join("kendex.toml"), format!("schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = ['copilot']\n[agents.worker]\nsource = 'cat'\n[model-bindings.copilot]\nstandard = 'claude-opus-4.6'\n", source_path(&catalog))).unwrap();
    let report = kendex_core::engine::audit(&env, &Scope::Project { root: project }).unwrap();
    // Copilot report consumers read the stable first line, not the explanation.
    assert!(report.warnings.iter().any(|row| row.message.lines().next() == Some("kendex-model-disallowed: harness=copilot agent=worker requested=claude-opus-4.6 allowed=gpt-6.1-sol")));
}

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
        for (class, policy) in ["top", "standard", "light", "fast"]
            .into_iter()
            .flat_map(|class| {
                [
                    BTreeMap::new(),
                    BTreeMap::from([(class.into(), "openai/gpt-6.1-sol".into())]),
                ]
                .map(|policy| (class, policy))
            })
        {
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
                model_classes: policy,
                model_bindings: Default::default(),
                permissions: EffectiveAgent::intent(&source, &Default::default()),
                launch_instructions: None,
                additional_instructions: None,
                custom_hooks: vec![],
                role_policy: None,
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
fn native_model_readback_rejects_malformed_selectors_after_shape_checks() {
    // Catalog authors can supply model text with a valid native shape but invalid syntax.
    for (harness, model) in [
        (HarnessId::Claude, "bad value"),
        (HarnessId::Codex, "bad value"),
        (HarnessId::Pi, "provider/bad value"),
        (HarnessId::Opencode, "provider/bad value"),
    ] {
        let text = match harness {
            HarnessId::Codex => format!(
                "name = \"worker\"\ndescription = \"Work\"\ndeveloper_instructions = \"Body\"\nmodel = {model:?}\n"
            ),
            _ => format!("---\nname: worker\ndescription: Work\nmodel: {model}\n---\nBody.\n"),
        };
        let findings = kendex_core::render::validate::validate_agent(harness, "worker", &text);
        assert!(
            findings.iter().any(|finding| finding.is_breakage()
                && finding
                    .message
                    .starts_with("kendex-model-selector-invalid:")),
            "{harness:?}/{model}"
        );
    }
    for harness in [HarnessId::Pi, HarnessId::Opencode] {
        let text = "---\nname: worker\ndescription: Work\nmodel: openrouter/anthropic/claude-sonnet-4\n---\nBody.\n";
        let findings = kendex_core::render::validate::validate_agent(harness, "worker", text);
        assert!(
            findings.iter().all(|finding| !finding.is_breakage()),
            "{harness:?}: {findings:?}"
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
    // A changed installed source record must not bind the declaration to another source.
    let lock_path = kendex_core::lock::lock_path(&env, &scope);
    let original_lock = fs::read_to_string(&lock_path).unwrap();
    let mut lock = kendex_core::lock::load(&lock_path).unwrap();
    let key = kendex_core::lock::entry_key(ItemKind::Agent, "worker", HarnessId::Claude);
    lock.entries.get_mut(&key).unwrap().source = "other".into();
    kendex_core::lock::save(&lock_path, &lock).unwrap();
    assert!(agent_model_request(&env, &project, HarnessId::Claude, "worker").is_err());
    fs::write(&lock_path, original_lock).unwrap();
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
fn declared_intent_keeps_installed_git_source_and_bundle_revision() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let key = kendex_core::lock::entry_key(ItemKind::Agent, "worker", HarnessId::Claude);
    // A refreshed Git catalog can coexist with agents installed from an earlier revision.
    let upstream = home.join("git/owner/catalog");
    let git_project = home.join("git-project");
    fs::create_dir_all(upstream.join("agents")).unwrap();
    fs::create_dir_all(git_project.join(".claude")).unwrap();
    crate::test_util::git(&upstream, &["init", "--quiet", "-b", "main"]);
    for name in ["worker", "bundled", "updated"] {
        fs::write(
            upstream.join(format!("agents/{name}.md")),
            format!("---\nname: {name}\ndescription: Work\nmodel: light\n---\nInstalled body.\n"),
        )
        .unwrap();
    }
    fs::write(upstream.join("kendex.toml"), "is_source_catalog = true\n[agent-frontmatter.claude.worker]\nmodel = \"fast\"\n[bundles.kit]\ndescription = \"Workers\"\nagents = [\"bundled\"]\n").unwrap();
    crate::test_util::git(&upstream, &["add", "-A"]);
    crate::test_util::git(&upstream, &["commit", "--quiet", "-m", "installed"]);
    let first = crate::test_util::git(&upstream, &["rev-parse", "HEAD"])
        .trim()
        .to_owned();
    let git_env = Env::fake(&home, FakeOs::Linux).with_var(
        "KENDEX_GIT_BASE",
        &format!("file://{}", home.join("git").display()),
    );
    let git_scope = Scope::Project {
        root: git_project.clone(),
    };
    let manifest_path = git_project.join("kendex.toml");
    fs::write(&manifest_path, "schema = 6\n[sources.cat]\nrepo = \"owner/catalog\"\n[install]\nharnesses = [\"claude\"]\n[agents.worker]\nsource = \"cat\"\n[agents.updated]\nsource = \"cat\"\n[bundles.kit]\nsource = \"cat\"\n").unwrap();
    let declared = manifest::load_current(&manifest_path).unwrap().unwrap();
    kendex_core::remote::sync_sources(&git_env, &declared).unwrap();
    let report = kendex_core::engine::audit(&git_env, &git_scope).unwrap();
    kendex_core::apply::execute(&git_env, &report.plan).unwrap();
    for name in ["worker", "bundled", "updated"] {
        fs::write(
            upstream.join(format!("agents/{name}.md")),
            format!(
                "---\nname: {name}\ndescription: Work\nmodel: standard\n---\nRefreshed body.\n"
            ),
        )
        .unwrap();
    }
    fs::write(upstream.join("kendex.toml"), "is_source_catalog = true\n[agent-frontmatter.claude.worker]\nmodel = \"top\"\n[bundles.kit]\ndescription = \"Workers\"\nagents = [\"updated\"]\n").unwrap();
    crate::test_util::git(&upstream, &["add", "-A"]);
    crate::test_util::git(&upstream, &["commit", "--quiet", "-m", "refreshed"]);
    let second = crate::test_util::git(&upstream, &["rev-parse", "HEAD"])
        .trim()
        .to_owned();
    assert_ne!(first, second);
    kendex_core::remote::sync_sources(&git_env, &declared).unwrap();
    let report =
        kendex_core::package::update_one(&git_env, &git_scope, ItemKind::Agent, "updated").unwrap();
    kendex_core::apply::execute(&git_env, &report.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&git_env, &git_scope);
    let lock = kendex_core::lock::load(&lock_path).unwrap();
    assert_eq!(
        lock.entries[&key].source_commit.as_deref(),
        Some(first.as_str())
    );
    assert_eq!(lock.sources["cat"].commit, second);
    assert_eq!(lock.bundles["kit"].commit, first);
    let cache_key = kendex_core::remote::cache_key(&git_env, "owner/catalog");
    let installed = kendex_core::remote::store::published(&git_env, &cache_key, &first).unwrap();
    let refreshed = kendex_core::remote::store::published(&git_env, &cache_key, &second).unwrap();
    let paths: Vec<_> = [upstream, installed, refreshed]
        .into_iter()
        .flat_map(|root| {
            [
                root.join("kendex.toml"),
                root.join("agents/worker.md"),
                root.join("agents/bundled.md"),
            ]
        })
        .chain([
            manifest_path,
            lock_path,
            git_project.join(".claude/agents/worker.md"),
            git_project.join(".claude/agents/bundled.md"),
        ])
        .collect();
    let before: Vec<_> = paths.iter().map(|path| fs::read(path).unwrap()).collect();
    for (name, expected) in [("worker", ModelClass::Fast), ("bundled", ModelClass::Light)] {
        match agent_model_request(&git_env, &git_project, HarnessId::Claude, name).unwrap() {
            AgentModelRequest::Managed { request, .. } => assert_eq!(
                request,
                ModelRequest::Class { class: expected },
                "{name}: installed revision intent"
            ),
            AgentModelRequest::Unmanaged => panic!("installed Git agent became unmanaged"),
        }
    }
    let after: Vec<_> = paths.iter().map(|path| fs::read(path).unwrap()).collect();
    assert_eq!(
        before, after,
        "lookup preserves sources, manifests, lock and native bytes"
    );
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
