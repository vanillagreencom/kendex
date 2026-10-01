use std::{collections::BTreeMap, fs};

use crate::test_util::rooted;
use kendex_core::{
    apply,
    engine::{self, ops},
    env::{Env, FakeOs},
    library::{self, Origin},
    manifest,
    model::{HarnessId, ItemKind, Scope},
    scan,
};
use serde_json::{Value, json};

#[test]
fn builtin_mcp_toggle_verify_and_removal_use_the_native_switch() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    fs::create_dir_all(home.join(".copilot")).unwrap();
    let scopes = [
        Scope::Global,
        Scope::Project {
            root: home.join("project"),
        },
    ];
    fs::create_dir_all(home.join("project")).unwrap();
    for scope in &scopes {
        let path = kendex_core::harness::copilot::settings::settings_file(&env, scope);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "{\"theme\":\"dark\",\"nested\":{\"keep\":[1,2]}}\n").unwrap();
        let before: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        let found = scan::scan_scopes(&env, &BTreeMap::new(), std::slice::from_ref(scope));
        let builtins: Vec<_> = found
            .items
            .iter()
            .filter(|i| i.file_state == kendex_core::model::FileState::Builtin)
            .collect();
        assert_eq!(
            builtins
                .iter()
                .map(|i| (i.name.as_str(), i.enabled))
                .collect::<Vec<_>>(),
            vec![("github-mcp-server", Some(true)), ("githubiq", Some(true))]
        );
        assert_eq!(
            library::provenance(&env, std::slice::from_ref(scope))
                .unwrap()
                .iter()
                .filter(|row| row.origin == Origin::Builtin)
                .count(),
            2
        );
        assert!(engine::audit(&env, scope).unwrap().drift.is_empty());
        assert_eq!(
            serde_json::from_str::<Value>(&fs::read_to_string(&path).unwrap()).unwrap(),
            before
        );

        let names = ["github-mcp-server".to_owned(), "githubiq".to_owned()];
        let report =
            ops::toggle(&env, scope, &names, Some(ItemKind::McpServer), false, None).unwrap();
        apply::execute(&env, &report.plan).unwrap();
        let saved = ops::manifest_for_reading(&env, scope).unwrap();
        let rows = library::provenance(&env, std::slice::from_ref(scope)).unwrap();
        assert_eq!(rows.len(), 2);
        assert!(
            rows.iter()
                .all(|row| row.origin == Origin::Builtin && row.package.is_some())
        );
        for name in &names {
            let decl = &saved.mcp_servers[name];
            assert_eq!(decl.source, "builtin");
            assert_eq!(decl.harnesses, Some(vec![HarnessId::Copilot]));
            assert!(!decl.enabled);
        }
        let mut disabled: Value =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            disabled["disabledMcpServers"],
            json!(["github-mcp-server", "githubiq"])
        );
        assert_eq!(disabled["theme"], before["theme"]);
        assert_eq!(disabled["nested"], before["nested"]);
        assert!(engine::audit(&env, scope).unwrap().drift.is_empty());
        // Native config is the verifier's evidence, not the matching lock.
        disabled["disabledMcpServers"] = json!(["githubiq"]);
        fs::write(&path, serde_json::to_string_pretty(&disabled).unwrap()).unwrap();
        let dirty = engine::audit(&env, scope).unwrap();
        assert!(
            dirty
                .drift
                .iter()
                .any(|row| row.name == "github-mcp-server")
        );
        apply::execute(&env, &dirty.plan).unwrap();
        let report = ops::toggle(&env, scope, &names[..1], None, true, None).unwrap();
        apply::execute(&env, &report.plan).unwrap();
        let enabled: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(enabled["disabledMcpServers"], json!(["githubiq"]));
        let report = ops::remove(&env, scope, &names, None, false).unwrap();
        apply::execute(&env, &report.plan).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&fs::read_to_string(&path).unwrap()).unwrap(),
            before
        );
        let clean = engine::audit(&env, scope).unwrap();
        assert!(clean.drift.is_empty());
        assert!(
            clean
                .installations
                .values()
                .all(|item| !names.contains(&item.name))
        );
    }
}

#[test]
fn native_mcp_settings_union_holds_and_bad_layers_never_report_on() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Project {
        root: home.join("project"),
    };
    fs::create_dir_all(home.join(".copilot")).unwrap();
    fs::create_dir_all(home.join("project/.github/copilot")).unwrap();
    fs::create_dir_all(home.join("project/.claude")).unwrap();
    let user = home.join(".copilot/settings.json");
    let repo = home.join("project/.github/copilot/settings.json");
    let local = home.join("project/.github/copilot/settings.local.json");
    fs::write(
        &user,
        "// native header\n{\"disabledMcpServers\":[\"github-mcp-server\"],}\n",
    )
    .unwrap();
    fs::write(&local, "{\"disabledMcpServers\":[\"githubiq\"]}").unwrap();
    fs::write(
        home.join("project/.claude/settings.json"),
        "{\"disabledMcpServers\":[\"ignored\"]}",
    )
    .unwrap();
    let names = kendex_core::harness::copilot::settings::disabled_mcps(&env, &scope).unwrap();
    assert_eq!(names, ["github-mcp-server", "githubiq"]);
    // The project has no declaration yet, but the native row is already off.
    let enabled = ops::toggle(
        &env,
        &scope,
        &["github-mcp-server".into()],
        None,
        true,
        None,
    )
    .unwrap();
    assert!(
        enabled
            .warnings
            .iter()
            .any(|warning| warning.message.starts_with("kendex-item-disabled:"))
    );
    apply::execute(&env, &enabled.plan).unwrap();
    let report = ops::toggle(
        &env,
        &scope,
        &["github-mcp-server".into()],
        None,
        false,
        None,
    )
    .unwrap();
    apply::execute(&env, &report.plan).unwrap();
    let report = ops::toggle(
        &env,
        &scope,
        &["github-mcp-server".into()],
        None,
        true,
        None,
    )
    .unwrap();
    assert!(
        report
            .warnings
            .iter()
            .any(|warning| warning.message.starts_with("kendex-item-disabled:"))
    );
    apply::execute(&env, &report.plan).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&fs::read_to_string(repo).unwrap()).unwrap(),
        json!({})
    );
    let read = scan::scan_scopes(&env, &BTreeMap::new(), std::slice::from_ref(&scope));
    assert_eq!(
        read.items
            .iter()
            .filter(|i| i.file_state == kendex_core::model::FileState::Builtin)
            .map(|i| (i.name.as_str(), i.enabled))
            .collect::<Vec<_>>(),
        vec![
            ("github-mcp-server", Some(false)),
            ("githubiq", Some(false))
        ]
    );
    for invalid in [
        "{",
        "{\"disabledMcpServers\":false}",
        "{\"disabledMcpServers\":[7]}",
    ] {
        fs::write(&user, invalid).unwrap();
        let read = scan::scan_scopes(&env, &BTreeMap::new(), std::slice::from_ref(&scope));
        assert!(
            read.items
                .iter()
                .all(|i| i.file_state != kendex_core::model::FileState::Builtin)
        );
        assert!(read.warnings.iter().any(|warning| warning.path == user));
        assert!(engine::audit(&env, &scope).is_err());
    }
}

#[test]
fn builtin_source_refuses_non_native_declarations_and_legacy_settings() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    fs::create_dir_all(home.join(".copilot")).unwrap();
    let scope = Scope::Global;
    for (kind, name, harness) in [
        (ItemKind::Skill, "githubiq", HarnessId::Copilot),
        (ItemKind::McpServer, "unknown", HarnessId::Copilot),
        (ItemKind::McpServer, "githubiq", HarnessId::Claude),
    ] {
        let mut manifest = manifest::Manifest::default();
        let mut decl = manifest::ItemDecl::from_source("builtin");
        decl.harnesses = Some(vec![harness]);
        manifest.declared_mut(kind).insert(name.into(), decl);
        let report = engine::plan_scope(
            &env,
            &scope,
            &manifest,
            &Default::default(),
            &Default::default(),
        )
        .unwrap();
        assert_eq!(
            report.declaration_status,
            engine::DeclarationStatus::Incomplete
        );
        assert!(report.installations.is_empty());
    }
    let settings = home.join(".copilot/settings.json");
    let legacy = home.join(".copilot/config.json");
    let path = manifest::manifest_path(&env, &scope);
    let lock_path = kendex_core::lock::lock_path(&env, &scope);
    let report = ops::toggle(&env, &scope, &["githubiq".into()], None, false, None).unwrap();
    apply::execute(&env, &report.plan).unwrap();
    assert!(engine::audit(&env, &scope).unwrap().drift.is_empty());
    // Copilot reset leaves the old file and removes the native switch's file.
    fs::write(&legacy, "{\"theme\":\"dark\"}").unwrap();
    fs::remove_file(&settings).unwrap();
    let before = fs::read(&path).unwrap();
    let recorded = fs::read(&lock_path).unwrap();
    assert!(matches!(
        engine::audit(&env, &scope),
        Err(kendex_core::error::CoreError::ConfigEdit { path, .. }) if path == settings
    ));
    for (name, enabled, observed) in [
        ("githubiq", true, None),
        (
            "githubiq",
            false,
            Some(kendex_core::model::FileState::Builtin),
        ),
        ("github-mcp-server", false, None),
    ] {
        assert!(matches!(
            ops::toggle(&env, &scope, &[name.into()], Some(ItemKind::McpServer), enabled, observed.as_ref()),
            Err(kendex_core::error::CoreError::ConfigEdit { path, .. }) if path == settings
        ));
        assert_eq!(fs::read(&path).unwrap(), before);
        assert_eq!(fs::read(&lock_path).unwrap(), recorded);
        assert!(!settings.exists());
        assert_eq!(fs::read_to_string(&legacy).unwrap(), "{\"theme\":\"dark\"}");
    }
}

#[test]
fn a_native_row_never_claims_or_toggles_a_same_named_catalog_server() {
    for (name, project, bundle) in [
        ("githubiq", false, false),
        ("githubiq", true, false),
        ("github-mcp-server", false, false),
        ("github-mcp-server", true, false),
        ("githubiq", false, true),
        ("githubiq", true, true),
        ("github-mcp-server", false, true),
        ("github-mcp-server", true, true),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let scope = if project {
            fs::create_dir_all(home.join("project/.github")).unwrap();
            Scope::Project {
                root: home.join("project"),
            }
        } else {
            Scope::Global
        };
        fs::create_dir_all(home.join(".copilot")).unwrap();
        let local = kendex_core::source::local_source_root(&env, &scope);
        fs::create_dir_all(local.join("mcp")).unwrap();
        fs::write(
            local.join("kendex.toml"),
            format!("is_source_catalog = true\n[bundles.starter]\nmcp-servers = [\"{name}\"]\n"),
        )
        .unwrap();
        fs::write(
            local.join(format!("mcp/{name}.toml")),
            "command = \"custom\"\n",
        )
        .unwrap();
        let mut declared = manifest::Manifest {
            schema: manifest::MANIFEST_SCHEMA,
            ..Default::default()
        };
        declared.install.harnesses = vec![HarnessId::Copilot];
        if bundle {
            declared
                .bundles
                .insert("starter".into(), manifest::ItemDecl::from_source("local"));
        } else {
            declared
                .mcp_servers
                .insert(name.into(), manifest::ItemDecl::from_source("local"));
        }
        let path = manifest::manifest_path(&env, &scope);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, toml::to_string(&declared).unwrap()).unwrap();
        let report = engine::audit(&env, &scope).unwrap();
        apply::execute(&env, &report.plan).unwrap();
        assert!(engine::audit(&env, &scope).unwrap().drift.is_empty());
        let rows = library::provenance(&env, std::slice::from_ref(&scope)).unwrap();
        let natives: Vec<_> = rows
            .iter()
            .filter(|row| row.origin == Origin::Builtin)
            .collect();
        assert_eq!(natives.len(), 2);
        assert!(natives.iter().all(|row| row.package.is_none()));
        let before = fs::read(&path).unwrap();
        let lock_path = kendex_core::lock::lock_path(&env, &scope);
        let recorded = fs::read(&lock_path).unwrap();
        let observations = if bundle {
            vec![None, Some(kendex_core::model::FileState::Builtin)]
        } else {
            vec![Some(kendex_core::model::FileState::Builtin)]
        };
        for observed in observations {
            assert!(matches!(
                ops::toggle(&env, &scope, &[name.into()], Some(ItemKind::McpServer), false, observed.as_ref()),
                Err(kendex_core::error::CoreError::SourceCollision { requested, .. }) if requested == "builtin"
            ));
            assert_eq!(fs::read(&path).unwrap(), before);
            assert_eq!(fs::read(&lock_path).unwrap(), recorded);
            assert!(!kendex_core::harness::copilot::settings::settings_file(&env, &scope).exists());
        }
    }
}

#[test]
fn a_bundle_native_named_member_can_be_declared_and_toggled_from_its_source() {
    for (name, project) in [
        ("githubiq", false),
        ("githubiq", true),
        ("github-mcp-server", false),
        ("github-mcp-server", true),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        fs::create_dir_all(home.join(".copilot")).unwrap();
        fs::create_dir_all(home.join("project/.github")).unwrap();
        let scope = if project {
            Scope::Project {
                root: home.join("project"),
            }
        } else {
            Scope::Global
        };
        let local = kendex_core::source::local_source_root(&env, &scope);
        fs::create_dir_all(local.join("mcp")).unwrap();
        fs::write(
            local.join("kendex.toml"),
            format!("is_source_catalog = true\n[bundles.starter]\nmcp-servers = [\"{name}\"]\n"),
        )
        .unwrap();
        fs::write(
            local.join(format!("mcp/{name}.toml")),
            "command = \"custom\"\n",
        )
        .unwrap();
        let mut declared = manifest::Manifest {
            schema: manifest::MANIFEST_SCHEMA,
            ..Default::default()
        };
        declared.install.harnesses = vec![HarnessId::Copilot];
        declared
            .bundles
            .insert("starter".into(), manifest::ItemDecl::from_source("local"));
        let path = manifest::manifest_path(&env, &scope);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, toml::to_string(&declared).unwrap()).unwrap();
        let report = engine::audit(&env, &scope).unwrap();
        apply::execute(&env, &report.plan).unwrap();
        let report = ops::add(
            &env,
            &scope,
            &ops::AddRequest {
                source: Some("local".into()),
                mcp_servers: vec![name.into()],
                ..Default::default()
            },
        )
        .unwrap();
        apply::execute(&env, &report.plan).unwrap();
        for enabled in [false, true] {
            let report = ops::toggle(
                &env,
                &scope,
                &[name.into()],
                Some(ItemKind::McpServer),
                enabled,
                None,
            )
            .unwrap();
            apply::execute(&env, &report.plan).unwrap();
            let saved = ops::manifest_for_reading(&env, &scope).unwrap();
            assert_eq!(saved.mcp_servers[name].source, "local");
            assert_eq!(saved.mcp_servers[name].enabled, enabled);
            assert!(engine::audit(&env, &scope).unwrap().drift.is_empty());
        }
    }
}

#[test]
fn a_builtin_record_never_claims_a_handwritten_registration() {
    for (name, project) in [
        ("githubiq", false),
        ("githubiq", true),
        ("github-mcp-server", false),
        ("github-mcp-server", true),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        fs::create_dir_all(home.join(".copilot")).unwrap();
        fs::create_dir_all(home.join("project/.github")).unwrap();
        let scope = if project {
            Scope::Project {
                root: home.join("project"),
            }
        } else {
            Scope::Global
        };
        let registry = if project {
            home.join("project/.github/mcp.json")
        } else {
            home.join(".copilot/mcp-config.json")
        };
        let custom = json!({"mcpServers": {name: {"type": "local", "command": "custom"}}});
        fs::write(&registry, serde_json::to_string(&custom).unwrap()).unwrap();
        let before = fs::read(&registry).unwrap();
        let report = ops::toggle(
            &env,
            &scope,
            &[name.into()],
            Some(ItemKind::McpServer),
            false,
            None,
        )
        .unwrap();
        apply::execute(&env, &report.plan).unwrap();
        for recorded in [true, false] {
            if !recorded {
                fs::remove_file(kendex_core::lock::lock_path(&env, &scope)).unwrap();
            }
            let rows = library::provenance(&env, std::slice::from_ref(&scope)).unwrap();
            let same_name: Vec<_> = rows.iter().filter(|row| row.name == name).collect();
            assert_eq!(same_name.len(), 2, "{name} {scope:?} recorded={recorded}");
            let native = same_name
                .iter()
                .find(|row| row.origin == Origin::Builtin)
                .unwrap();
            assert_eq!(native.package.is_some(), recorded);
            let custom = same_name
                .iter()
                .find(|row| row.origin == Origin::Unmanaged)
                .unwrap();
            assert!(custom.package.is_none());
            assert_eq!(fs::read(&registry).unwrap(), before);
        }
    }
}
