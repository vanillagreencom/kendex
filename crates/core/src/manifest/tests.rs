use super::*;
use crate::error::CoreError;
use crate::model::ItemKind;

#[test]
fn round_trips_the_binding_skeleton() {
    let text = r#"
schema = 1

[sources.vstack]
repo = "vanillagreencom/vstack"
enabled = true

[install]
harnesses = ["claude", "pi"]
method = "symlink"

[agents.orch]
source = "vstack"

[skills.github]
source = "vstack"
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
        manifest.sources["vstack"].repo.as_deref(),
        Some("vanillagreencom/vstack")
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

#[test]
fn schema_less_file_is_legacy_and_never_a_mutation_target() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("kendex.toml");
    let v1 = "[agent-skills]\nrust = [\"clippy\"]\n";
    std::fs::write(&path, v1).unwrap();

    assert!(matches!(load(&path).unwrap(), ManifestFile::Legacy { .. }));
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
    assert!(crate::rename::is_source_catalog(root));
    assert_eq!(
        crate::manifest::manifest_path(&env, &scope)
            .file_name()
            .unwrap(),
        "kendex-local.toml",
    );

    // The flag off is not a catalog: back to the project's own kendex.toml.
    std::fs::write(root.join("kendex.toml"), "is_source_catalog = false\n").unwrap();
    assert!(!crate::rename::is_source_catalog(root));
    assert_eq!(
        crate::manifest::manifest_path(&env, &scope)
            .file_name()
            .unwrap(),
        "kendex.toml",
    );
}

// The base is what a copy in hand remembers about the file it came from,
// and the only thing that can tell a write from an overwrite: the caller
// that read the file may be gone, and a caller that never asked cannot be
// made to.
mod stale_writes {
    use super::super::{Base, check_base};

    #[allow(clippy::unwrap_used)]
    fn file(dir: &std::path::Path, text: &str) -> std::path::PathBuf {
        let path = dir.join("kendex.toml");
        std::fs::write(&path, text).unwrap();
        path
    }

    /// The pairing, where it can be seen: the base is taken over the exact
    /// bytes the manifest was parsed from. Read apart — parse the file,
    /// then hash it — a writer landing in between hands back the old
    /// manifest under the new file's base, and the write that follows is
    /// accepted over that writer.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn the_base_belongs_to_the_bytes_the_manifest_came_from() {
        // Through the module, since the pairing is not offered beyond it.
        use super::super::file::parse_with_base;
        use super::super::{Base, read_for_mutation};
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("kendex.toml");
        let text = "schema = 5\n";
        std::fs::write(&path, text).unwrap();

        let (parsed, paired) = parse_with_base(&path, text).unwrap();
        assert!(parsed.is_some());
        // The same bytes, whether the file or the caller handed them over.
        assert_eq!(paired, Base::of(text));
        assert_eq!(read_for_mutation(&path).unwrap().1, paired);

        // Bytes that are not the file's answer for themselves, never for it.
        let (_, other) = parse_with_base(&path, "schema = 5\n# later\n").unwrap();
        assert_ne!(other, paired);
    }

    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_copy_of_the_file_it_came_from_writes() {
        let tmp = tempfile::tempdir().unwrap();
        let path = file(tmp.path(), "schema = 5\n");
        let (_, held) = super::super::read_for_mutation(&path).unwrap();

        assert_ne!(held, Base::absent(), "a file that is there has a base");
        assert!(check_base(&path, &held).is_ok());
    }

    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_copy_of_what_the_file_used_to_be_does_not() {
        let tmp = tempfile::tempdir().unwrap();
        let path = file(tmp.path(), "schema = 5\n");
        let (_, held) = super::super::read_for_mutation(&path).unwrap();
        // Something else rewrote it — a fork, a hold, a dismissal.
        file(
            tmp.path(),
            "schema = 5\n\n[forks.skill.gh]\nsource = \"cat\"\n",
        );

        assert!(check_base(&path, &held).is_err());
    }

    #[test]
    #[allow(clippy::unwrap_used)]
    fn nothing_read_and_nothing_there_writes_the_first_one() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("kendex.toml");

        assert_eq!(
            super::super::read_for_mutation(&path).unwrap().1,
            Base::absent()
        );
        assert!(check_base(&path, &Base::absent()).is_ok());
    }

    #[test]
    #[allow(clippy::unwrap_used)]
    fn nothing_read_but_something_there_now_does_not() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("kendex.toml");
        let (_, held) = super::super::read_for_mutation(&path).unwrap();
        // Between the read and the write, the place got its first manifest.
        file(tmp.path(), "schema = 5\n");

        assert!(check_base(&path, &held).is_err());
    }
}
