use super::*;
use crate::error::CoreError;
use crate::model::ItemKind;

#[test]
fn round_trips_the_binding_skeleton() {
    let text = r#"
schema = 6

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
fn seed_declares_the_default_source_once() {
    let manifest = seed(&[HarnessId::Claude]);
    // Spelled out: a fresh scope seeds the post-rename name and repo.
    assert_eq!(
        manifest.sources["kendex"].repo.as_deref(),
        Some("vanillagreencom/kendex")
    );
    assert!(manifest.sources[DEFAULT_SOURCE_NAME].enabled);
    assert_eq!(manifest.declared(ItemKind::Agent).len(), 0);
    assert_eq!(manifest.install.harnesses, [HarnessId::Claude]);
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
