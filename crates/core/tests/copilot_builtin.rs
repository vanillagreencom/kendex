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
    assert!(
        read.items
            .iter()
            .filter(|i| i.file_state == kendex_core::model::FileState::Builtin)
            .all(|i| i.enabled == Some(false))
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
    fs::write(home.join(".copilot/config.json"), "{}").unwrap();
    let report = ops::toggle(&env, &scope, &["githubiq".into()], None, false, None).unwrap();
    assert_eq!(
        report.declaration_status,
        engine::DeclarationStatus::Incomplete
    );
    apply::execute(&env, &report.plan).unwrap();
    assert!(!home.join(".copilot/settings.json").exists());
}

#[test]
fn a_native_row_never_claims_or_toggles_a_same_named_catalog_server() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Global;
    fs::create_dir_all(home.join(".copilot")).unwrap();
    let local = kendex_core::source::local_source_root(&env, &scope);
    fs::create_dir_all(local.join("mcp")).unwrap();
    fs::write(local.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(local.join("mcp/githubiq.toml"), "command = \"custom\"\n").unwrap();
    let mut declared = manifest::Manifest {
        schema: manifest::MANIFEST_SCHEMA,
        ..Default::default()
    };
    declared.install.harnesses = vec![HarnessId::Copilot];
    declared
        .mcp_servers
        .insert("githubiq".into(), manifest::ItemDecl::from_source("local"));
    let path = manifest::manifest_path(&env, &scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, toml::to_string(&declared).unwrap()).unwrap();
    let report = engine::audit(&env, &scope).unwrap();
    apply::execute(&env, &report.plan).unwrap();
    let rows = library::provenance(&env, std::slice::from_ref(&scope)).unwrap();
    let natives: Vec<_> = rows
        .iter()
        .filter(|row| row.origin == Origin::Builtin)
        .collect();
    assert_eq!(natives.len(), 2);
    assert!(natives.iter().all(|row| row.package.is_none()));
    let before = fs::read(&path).unwrap();
    let result = ops::toggle(
        &env,
        &scope,
        &["githubiq".into()],
        Some(ItemKind::McpServer),
        false,
        Some(&kendex_core::model::FileState::Builtin),
    );
    assert!(matches!(
        result,
        Err(kendex_core::error::CoreError::SourceCollision { .. })
    ));
    assert_eq!(fs::read(&path).unwrap(), before);
    assert!(!kendex_core::harness::copilot::settings::settings_file(&env, &scope).exists());
}
