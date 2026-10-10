use super::*;
use crate::error::CoreError;
use crate::model::ItemKind;

#[test]
fn save_migrates_hand_edited_text_before_folding_the_mutation() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let path = root.join("kendex.toml");
    // Git checkouts and editors emit each string form with either terminator.
    let strings = [
        ("basic", r#""line one\r\nline two\\path""#),
        ("literal", "'line one\\nline two'"),
        ("multiline basic", "\"\"\"\nline one\nline two café\n\"\"\""),
        ("multiline literal", "'''\nline one\nline two café\n'''"),
        ("basic continuation", "\"\"\"line one\\\n  line two\n\"\"\""),
    ];
    for (form, value) in strings {
        for (schema, newline) in [(6, "\n"), (6, "\r\n"), (7, "\n"), (7, "\r\n")] {
            for final_newline in [false, true] {
                let original = format!(
                    "# my setup\nschema = {schema}   # pinned\n\n[sources.cat]\nrepo = 'owner/catalog'   # source\n\n[skills.gh]\nsource = 'cat'\nnote = {value}\nenabled = true   # still on\n\n[[custom-hooks]]\nevent = 'Stop'\ncommand = {value}\ndescription = {value}\n\n[hooks.guard]\nsource = 'cat'\n\n[hooks.guard.env]\nMESSAGE = {value}\n\n[agent-launch-instructions]\nall = {value}\n\n[agent-additional-instructions]\nall = {value}\n\n[skill-instructions]\nall = {value}\n\n[command-instructions]\nall = {value}\n\n[bot-instructions]\nvalue = {value}\nlist = [{value}]\ninline = {{ text = {value} }}\n\n[[bot-instructions.entries]]\ntext = {value}"
                );
                let original = if final_newline {
                    format!("{original}\n")
                } else {
                    original
                }
                .replace('\n', newline);
                std::fs::write(&path, &original).unwrap();
                let mut manifest = load_current(&path).unwrap().unwrap();
                let expected = original
                    .replacen("schema = 6", "schema = 7", 1)
                    .replace("enabled = true", "enabled = false");
                if schema == 6 {
                    assert_eq!(
                        manifest.migrated_text.as_deref(),
                        Some(original.replacen("schema = 6", "schema = 7", 1).as_str()),
                        "{form} migration"
                    );
                }
                manifest.skills.get_mut("gh").unwrap().enabled = false;
                save(&path, &manifest).unwrap();
                assert_eq!(
                    std::fs::read_to_string(&path).unwrap(),
                    expected,
                    "{form}, schema {schema}, final terminator {final_newline}"
                );
                let reloaded = load_current(&path).unwrap().unwrap();
                assert!(!reloaded.skills["gh"].enabled);
                assert_eq!(reloaded.skill_instructions, manifest.skill_instructions);
                let on_wire = serde_json::to_value(&manifest).unwrap();
                assert!(on_wire.get("migration-notes").is_none());
                assert!(on_wire.get("migrated-text").is_none());
            }
        }
    }
}

#[test]
fn catalog_alias_uses_the_native_catalog_basename() {
    // Add and subscription requests carry native local paths or remote references.
    let sep = std::path::MAIN_SEPARATOR;
    let native = format!("C:{sep}catalogs{sep}builtin");
    let manifest = Manifest::default();
    for (reference, expected) in [
        (native.clone(), "builtin-2"),
        (format!("{native}{sep}"), "builtin-2"),
        (format!("{native}.git{sep}"), "builtin-2"),
        ("git@example.com:catalogs/builtin.git/".into(), "builtin-2"),
        #[cfg(unix)]
        ("/catalogs/literal\\builtin".into(), "literal\\builtin"),
        #[cfg(unix)]
        ("/catalogs/builtin\\".into(), "builtin\\"),
    ] {
        assert_eq!(
            catalog_alias(&manifest, &reference),
            expected,
            "{reference}"
        );
    }
}

#[test]
fn bot_instructions_survive_manifest_and_app_round_trips() {
    let text = include_str!("../../../../skills/bot-instructions/tests/fixtures/canonical.toml");
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let path = root.join("kendex.toml");
    std::fs::write(&path, text).unwrap();
    let manifest = load_current(&path).unwrap().unwrap();
    let app = serde_json::to_string(&manifest).unwrap();
    let received: Manifest = serde_json::from_str(&app).unwrap();
    let fresh = root.join("saved.toml");
    save(&fresh, &received).unwrap();
    let original: toml::Table = toml::from_str(text).unwrap();
    let saved: toml::Table = toml::from_str(&std::fs::read_to_string(fresh).unwrap()).unwrap();
    assert_eq!(saved["bot-instructions"], original["bot-instructions"]);
}

#[test]
fn round_trips_the_binding_skeleton() {
    let text = r#"
schema = 7

[model-bindings.codex]
standard = "gpt-6.1-sol"

[sources.kendex]
repo = "vanillagreencom/kendex"
enabled = true

[install]
harnesses = ["claude", "pi"]
method = "symlink"

[agents.orch]
source = "kendex"

[skills.github]
source = "kendex"
method = "copy"
enabled = false

[agent-skills]
orch = ["github"]

[agent-frontmatter.claude.orch]
model = "opus"
deny-tools = ["WebSearch"]

[[custom-hooks]]
event = "PreToolUse"
matcher = "Bash"
command = "./guard.sh"

[skill-instructions]
github = "prefer gh cli"
"#;
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("kendex.toml");
    std::fs::write(&path, text).unwrap();

    let ManifestFile::Current(manifest) = load(&path).unwrap() else {
        panic!("expected current manifest");
    };
    assert_eq!(manifest.schema, 7);
    assert_eq!(manifest.model_bindings["codex"]["standard"], "gpt-6.1-sol");
    assert_eq!(
        manifest.sources["kendex"].repo.as_deref(),
        Some("vanillagreencom/kendex")
    );
    assert_eq!(
        manifest.install.harnesses,
        [HarnessId::Claude, HarnessId::Pi]
    );
    assert!(!manifest.skills["github"].enabled);
    assert_eq!(manifest.skills["github"].method, Some(Method::Copy));
    assert_eq!(
        manifest.agent_frontmatter["claude"]["orch"].deny_tools,
        Some(vec!["WebSearch".to_owned()])
    );
    assert_eq!(manifest.custom_hooks[0].event, "PreToolUse");

    save(&path, &manifest).unwrap();
    let ManifestFile::Current(reloaded) = load(&path).unwrap() else {
        panic!("expected current manifest after save");
    };
    assert_eq!(reloaded, manifest);
}

/// The tables schema 6 retired. A file still carrying them is a file from
/// before schema 6, and it is refused whole rather than read with the
/// records quietly dropped — the drop would go durable on the next write,
/// over every other byte the person put there.
#[test]
#[allow(clippy::unwrap_used)]
fn safety_decision_tables_are_refused_with_the_file_they_are_in() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("kendex.toml");
    let recorded = r#"
schema = 5

[sources.cat]
repo = "owner/repo"

[skills.deploy]
source = "cat"

[safety-overrides."skill:deploy:claude"]
review-hash = "abc"
ruleset = 3
findings = ["f1"]
granted-at = "2026-01-01T00:00:00Z"

[safety-reviews."skill:deploy:claude"]
review-hash = "abc"
ruleset = 3

[safety-reviews."skill:deploy:claude".dismissed.f2]
reason = "intended"
dismissed-at = "2026-01-01T00:00:00Z"
"#;
    std::fs::write(&path, recorded).unwrap();

    let refused = load_for_mutation(&path).unwrap_err();
    assert!(
        matches!(refused, CoreError::LegacyManifest { .. }),
        "{refused}"
    );
    assert!(refused.to_string().contains("schema 5"), "{refused}");
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        recorded,
        "and the file is left exactly as it was written"
    );
}

#[test]
fn schema_less_file_is_refused_and_never_a_mutation_target() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("kendex.toml");
    let v1 = "[agent-skills]\nrust = [\"clippy\"]\n";
    std::fs::write(&path, v1).unwrap();

    assert!(matches!(load(&path), Err(CoreError::LegacyManifest { .. })));
    assert!(matches!(
        load_for_mutation(&path),
        Err(CoreError::LegacyManifest { .. })
    ));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), v1);
}

#[test]
fn seed_declares_the_default_source_in_the_personal_scope_only() {
    use crate::model::Scope;

    let project = Scope::Project {
        root: std::path::PathBuf::from("/srv/app"),
    };
    // Spelled out: the personal scope seeds the post-rename name and repo;
    // a project seeds its tools and nothing to read from.
    for (scope, sources) in [
        (Scope::Global, vec![("kendex", "vanillagreencom/kendex")]),
        (project, vec![]),
    ] {
        let manifest = seed(&scope, &[HarnessId::Claude]);
        let seeded: Vec<(&str, &str)> = manifest
            .sources
            .iter()
            .map(|(name, decl)| (name.as_str(), decl.repo.as_deref().unwrap_or_default()))
            .collect();
        assert_eq!(seeded, sources, "{scope:?}");
        assert!(manifest.sources.values().all(|decl| decl.enabled));
        assert_eq!(manifest.schema, MANIFEST_SCHEMA);
        assert_eq!(manifest.declared(ItemKind::Agent).len(), 0);
        assert_eq!(manifest.install.harnesses, [HarnessId::Claude]);
    }
}

#[test]
fn source_catalog_routes_install_state_to_a_sibling() {
    use crate::env::{Env, FakeOs};
    use crate::model::Scope;

    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    let env = Env::fake(root, FakeOs::Linux);
    let scope = Scope::Project {
        root: root.to_path_buf(),
    };

    // No catalog marker: install state lives in the project's own kendex.toml.
    assert_eq!(
        crate::manifest::manifest_path(&env, &scope)
            .file_name()
            .unwrap(),
        "kendex.toml",
    );

    // A source catalog keeps kendex.toml as its definition and routes install
    // state to the sibling instead.
    std::fs::write(
        root.join("kendex.toml"),
        "is_source_catalog = true\n[marketplace]\nname = \"c\"\n",
    )
    .unwrap();
    assert!(crate::manifest::is_source_catalog(root));
    assert_eq!(
        crate::manifest::manifest_path(&env, &scope)
            .file_name()
            .unwrap(),
        "kendex-local.toml",
    );

    // The flag off is not a catalog: back to the project's own kendex.toml.
    std::fs::write(root.join("kendex.toml"), "is_source_catalog = false\n").unwrap();
    assert!(!crate::manifest::is_source_catalog(root));
    assert_eq!(
        crate::manifest::manifest_path(&env, &scope)
            .file_name()
            .unwrap(),
        "kendex.toml",
    );
}
mod scope_manifest_messages {
    use crate::env::{Env, FakeOs};
    use crate::model::Scope;

    #[test]
    #[allow(clippy::unwrap_used)]
    fn display_names_follow_project_routing_and_the_global_manifest() {
        for (marker, file) in [
            ("", "kendex.toml"),
            ("is_source_catalog = false\n", "kendex.toml"),
            ("is_source_catalog = true\n", "kendex-local.toml"),
        ] {
            let tmp = tempfile::tempdir().unwrap();
            let root = crate::test_util::rooted(&tmp);
            std::fs::write(root.join("kendex.toml"), marker).unwrap();
            let scope = Scope::Project { root: root.clone() };
            for os in [FakeOs::Linux, FakeOs::Mac, FakeOs::Windows] {
                let env = Env::fake(&root, os);
                assert_eq!(super::manifest_file_name(&env, &scope), file);
                assert_eq!(
                    super::manifest_file_name(&env, &Scope::Global),
                    "kendex.toml"
                );
            }
        }
    }
}
