use super::*;
use crate::env::FakeOs;
use crate::manifest::{MANIFEST_SCHEMA, SourceDecl};
use crate::model::ItemKind;
use crate::source_read::SealedSource;

fn manifest_with(name: &str, decl: SourceDecl) -> Manifest {
    let mut manifest = Manifest {
        schema: MANIFEST_SCHEMA,
        ..Manifest::default()
    };
    manifest.sources.insert(name.to_owned(), decl);
    manifest
}

#[test]
fn remote_without_cache_is_pending_not_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let manifest = manifest_with(
        "vstack",
        SourceDecl {
            repo: Some("vanillagreencom/vstack".into()),
            path: None,
            rev: None,
            enabled: true,
        },
    );
    let state = resolve(&env, &Scope::Global, "vstack", &manifest).unwrap();
    assert!(matches!(state, SourceState::Pending { .. }));
    assert!(matches!(
        require_ready(&env, &Scope::Global, "vstack", &manifest),
        Err(CoreError::SourcePending { .. })
    ));
}

#[test]
fn path_sources_resolve_relative_to_scope_root() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("proj");
    std::fs::create_dir_all(project.join("catalog/skills/gh")).unwrap();
    std::fs::write(project.join("catalog/skills/gh/SKILL.md"), "x").unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let manifest = manifest_with(
        "cat",
        SourceDecl {
            repo: None,
            path: Some("catalog".into()),
            rev: None,
            enabled: true,
        },
    );
    let scope = Scope::Project {
        root: project.clone(),
    };
    let source = require_ready(&env, &scope, "cat", &manifest).unwrap();
    assert_eq!(source.root, project.join("catalog").canonicalize().unwrap());

    let sealed = SealedSource::open(&source.root).unwrap();
    let config = source_config(&sealed, "catalog").unwrap();
    assert_eq!(
        find_item(&sealed, &config, ItemKind::Skill, "gh"),
        Some(source.root.join("skills/gh"))
    );
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["gh"]);
}

#[test]
fn disabled_and_missing_and_unknown_sources_are_distinct() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let mut manifest = manifest_with(
        "off",
        SourceDecl {
            repo: Some("a/b".into()),
            path: None,
            rev: None,
            enabled: false,
        },
    );
    manifest.sources.insert(
        "gone".into(),
        SourceDecl {
            repo: None,
            path: Some("nowhere".into()),
            rev: None,
            enabled: true,
        },
    );
    assert!(matches!(
        resolve(&env, &Scope::Global, "off", &manifest).unwrap(),
        SourceState::Disabled { .. }
    ));
    assert!(matches!(
        resolve(&env, &Scope::Global, "gone", &manifest).unwrap(),
        SourceState::Missing { .. }
    ));
    assert!(matches!(
        resolve(&env, &Scope::Global, "nope", &manifest),
        Err(CoreError::UnknownSource { .. })
    ));
}

#[test]
fn phase_three_kinds_live_at_fixed_catalog_paths() {
    let tmp = tempfile::tempdir().unwrap();
    let sealed = SealedSource::open(tmp.path()).unwrap();
    let root = sealed.root().to_path_buf();
    // Executable kinds live at fixed paths only when the catalog declared
    // kendex's layout. A discovered catalog never resolves them by name, so a
    // repo whose About report offers no hooks cannot hand one over on request.
    let explicit = SourceConfig {
        mode: CatalogMode::Explicit,
        ..SourceConfig::default()
    };
    for (kind, rel) in [
        (ItemKind::Hook, "hooks/guard.sh"),
        (ItemKind::Command, "commands/ship.md"),
        (ItemKind::McpServer, "mcp/gh.toml"),
    ] {
        let path = root.join(rel);
        std::fs::create_dir_all(root.join(rel).parent().unwrap()).unwrap();
        std::fs::write(&path, "x").unwrap();
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        // Present on disk, but a discovered catalog does not offer it.
        assert_eq!(
            find_item(&sealed, &SourceConfig::default(), kind, &name),
            None
        );
        assert_eq!(find_item(&sealed, &explicit, kind, &name), Some(path));
    }
}

/// A catalog's own words end up on a terminal. Whatever it writes about
/// itself is reported as text, never as the escape sequence it was.
#[test]
fn a_catalog_never_talks_to_the_terminal_through_a_finding() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(tmp.path().join(".claude-plugin")).unwrap();
    std::fs::write(
        tmp.path().join(".claude-plugin/marketplace.json"),
        r#"{"name": "cat", "owner": {"name": "o"}, "plugins": [
             {"name": "we\u001b[31mird", "source": "./plugins/weird"},
             {"name": "quiet", "source": "./plugins/q\u0000uiet"}]}"#,
    )
    .unwrap();
    let metadata = catalog_metadata(&SealedSource::open(tmp.path()).unwrap())
        .unwrap()
        .unwrap();
    let said = metadata
        .findings
        .iter()
        .map(CatalogFinding::to_string)
        .collect::<String>();
    assert!(said.contains("\\u{1b}") && said.contains("\\0"), "{said:?}");
    assert!(!said.contains('\u{1b}') && !said.contains('\0'), "{said:?}");
}

#[test]
fn v1_catalog_tables_parse_leniently() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(
        tmp.path().join("kendex.toml"),
        r#"
is_source_catalog = true
[catalog]
skills = ["skills", "extra-skills"]
[agent-skills]
rust = ["clippy"]
[role-skills]
engineer = ["dev"]
"#,
    )
    .unwrap();
    let config = source_config(&SealedSource::open(tmp.path()).unwrap(), "cat").unwrap();
    assert_eq!(config.skill_dirs, ["skills", "extra-skills"]);
    assert_eq!(config.agent_skills["rust"], ["clippy"]);
    assert_eq!(config.role_skills["engineer"], ["dev"]);
}

/// A declared-layout catalog lists only names that install: a deceptive or
/// otherwise unusable directory name is not drawn as a row find_item would
/// refuse, and never as an on-screen name that differs from the one on disk.
#[test]
fn an_explicit_catalog_does_not_list_names_it_cannot_install() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    std::fs::write(root.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    for dir in ["ok", "pay\u{202e}gnp.exe", "-rf", "nul"] {
        std::fs::create_dir_all(root.join("skills").join(dir)).unwrap();
        std::fs::write(root.join("skills").join(dir).join("SKILL.md"), "body").unwrap();
    }
    let sealed = SealedSource::open(root).unwrap();
    let config = source_config(&sealed, "cat").unwrap();
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["ok"]);
    // What is listed is exactly what find_item resolves.
    for name in ["pay\u{202e}gnp.exe", "-rf", "nul"] {
        assert_eq!(find_item(&sealed, &config, ItemKind::Skill, name), None);
    }
    assert!(find_item(&sealed, &config, ItemKind::Skill, "ok").is_some());
}

/// A namespaced `plugin/item` name — a plugin-registry package detached into
/// the local source — coexists with a plain `plugin` name: both are listed and
/// both resolve, neither hiding the other. Same for the file-per-item kinds.
#[test]
fn nested_and_plain_names_coexist_in_a_declared_layout() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().canonicalize().unwrap();
    let root = root.as_path();
    std::fs::write(root.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    for rel in ["skills/plugin", "skills/plugin/item"] {
        std::fs::create_dir_all(root.join(rel)).unwrap();
        std::fs::write(root.join(rel).join("SKILL.md"), "body").unwrap();
    }
    std::fs::create_dir_all(root.join("agents/team")).unwrap();
    std::fs::write(root.join("agents/lead.md"), "---\nname: lead\n---\n").unwrap();
    std::fs::write(root.join("agents/team/dev.md"), "---\nname: dev\n---\n").unwrap();

    let sealed = SealedSource::open(root).unwrap();
    let config = source_config(&sealed, "cat").unwrap();

    let skills = list_items(&sealed, &config, ItemKind::Skill);
    assert_eq!(skills, ["plugin", "plugin/item"]);
    assert_eq!(
        find_item(&sealed, &config, ItemKind::Skill, "plugin/item"),
        Some(root.join("skills/plugin/item"))
    );
    assert!(find_item(&sealed, &config, ItemKind::Skill, "plugin").is_some());

    let agents = list_items(&sealed, &config, ItemKind::Agent);
    assert_eq!(agents, ["lead", "team/dev"]);
    assert_eq!(
        find_item(&sealed, &config, ItemKind::Agent, "team/dev"),
        Some(root.join("agents/team/dev.md"))
    );
}

#[test]
fn a_catalog_still_naming_its_config_vstack_toml_is_read() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(
        tmp.path().join("vstack.toml"),
        "[catalog]\nskills = [\"old-skills\"]\n",
    )
    .unwrap();
    let config = source_config(&SealedSource::open(tmp.path()).unwrap(), "cat").unwrap();
    assert_eq!(config.skill_dirs, ["old-skills"]);
}

#[test]
fn a_catalog_carrying_both_config_names_agreeing_is_served_from_kendex_toml() {
    let tmp = tempfile::tempdir().unwrap();
    let body = "[catalog]\nskills = [\"new-skills\"]\n";
    std::fs::write(tmp.path().join("kendex.toml"), body).unwrap();
    // Formatting may differ; what must agree is what the files say.
    std::fs::write(
        tmp.path().join("vstack.toml"),
        "[catalog]\nskills = [ \"new-skills\" ]\n",
    )
    .unwrap();
    let config = source_config(&SealedSource::open(tmp.path()).unwrap(), "cat").unwrap();
    assert_eq!(config.skill_dirs, ["new-skills"]);
}

#[test]
fn both_config_generations_disagreeing_are_an_ambiguity_error_naming_both() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(
        tmp.path().join("kendex.toml"),
        "[catalog]\nskills = [\"new-skills\"]\n",
    )
    .unwrap();
    std::fs::write(
        tmp.path().join("vstack.toml"),
        "[catalog]\nskills = [\"old-skills\"]\n",
    )
    .unwrap();
    match source_config(&SealedSource::open(tmp.path()).unwrap(), "cat") {
        Err(CoreError::CatalogAmbiguous { new, old }) => {
            assert!(new.ends_with("kendex.toml"), "{new:?}");
            assert!(old.ends_with("vstack.toml"), "{old:?}");
        }
        other => panic!("expected the ambiguity error, got {other:?}"),
    }
}

#[test]
fn a_broken_old_generation_beside_a_readable_new_one_is_not_ambiguous() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(
        tmp.path().join("kendex.toml"),
        "[catalog]\nskills = [\"new-skills\"]\n",
    )
    .unwrap();
    std::fs::write(tmp.path().join("vstack.toml"), "not = = toml").unwrap();
    let config = source_config(&SealedSource::open(tmp.path()).unwrap(), "cat").unwrap();
    assert_eq!(config.skill_dirs, ["new-skills"]);
}

#[test]
fn a_local_source_left_under_the_old_name_still_reads() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("proj");
    std::fs::create_dir_all(project.join(".vstack-local/skills/handmade")).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    assert_eq!(
        local_source_root(&env, &scope),
        project.join(".vstack-local")
    );
    let state = resolve(&env, &scope, LOCAL_SOURCE_NAME, &Manifest::default()).unwrap();
    match state {
        SourceState::Ready(ready) => assert_eq!(ready.root, project.join(".vstack-local")),
        other => panic!("expected the old-name local source to read: {other:?}"),
    }
    // The new name wins the moment it exists — the rename op created it.
    std::fs::create_dir_all(project.join(".kendex-local")).unwrap();
    assert_eq!(
        local_source_root(&env, &scope),
        project.join(".kendex-local")
    );
}

/// A declared Pi package is on offer wherever its package.json registers
/// the name — the literal directory, or a short directory shelving a
/// scoped name the way kendex's own catalog does.
#[test]
fn a_pi_extension_is_found_literal_or_by_registered_name() {
    let tmp = tempfile::tempdir().unwrap();
    let catalog = tmp.path().join("catalog");
    std::fs::create_dir_all(catalog.join("pi-extensions/pi-hooks")).unwrap();
    std::fs::write(
        catalog.join("pi-extensions/pi-hooks/package.json"),
        "{\"name\": \"@vg/pi-hooks\", \"version\": \"1.0.0\"}",
    )
    .unwrap();

    let sealed = SealedSource::open(&catalog).unwrap();
    let config = source_config(&sealed, "catalog").unwrap();
    assert_eq!(
        find_item(&sealed, &config, ItemKind::PiExtension, "pi-hooks"),
        Some(sealed.root().join("pi-extensions/pi-hooks"))
    );
    assert_eq!(
        find_item(&sealed, &config, ItemKind::PiExtension, "@vg/pi-hooks"),
        Some(sealed.root().join("pi-extensions/pi-hooks"))
    );
    assert_eq!(
        find_item(&sealed, &config, ItemKind::PiExtension, "@vg/pi-ghost"),
        None
    );
}
