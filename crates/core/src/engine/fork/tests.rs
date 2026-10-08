//! KEN-1711 requires a filename assertion on the fork's edit instruction.

use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn absorbing_catalog_settings_names_the_declaring_file() {
    for (catalog, file) in [(true, "kendex-local.toml"), (false, "kendex.toml")] {
        let tmp = tempfile::tempdir().unwrap();
        let home = crate::test_util::rooted(&tmp);
        let root = home.join("app");
        std::fs::create_dir_all(root.join(".claude")).unwrap();
        if catalog {
            std::fs::write(root.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
        }
        let env = Env::fake(&home, crate::env::FakeOs::Linux);
        let scope = Scope::Project { root: root.clone() };
        let local = local_source_root(&env, &scope);
        std::fs::create_dir_all(local.join("agents")).unwrap();
        std::fs::write(
            local.join("agents/rev.md"),
            "---\nname: rev\ndescription: reviews\n---\nReview.\n",
        )
        .unwrap();
        std::fs::write(
            local.join("kendex.toml"),
            "[agent-frontmatter.claude-code.rev]\nmodel = \"sonnet\"\n",
        )
        .unwrap();
        std::fs::write(
            root.join(file),
            "schema = 6\n[install]\nharnesses = [\"claude\"]\n[agents.rev]\nsource = \"local\"\n",
        )
        .unwrap();
        let report = crate::engine::audit(&env, &scope).unwrap();
        crate::apply::execute(&env, &report.plan).unwrap();
        let edited = root.join(".claude/agents/rev.md");
        let text = std::fs::read_to_string(&edited).unwrap();
        assert!(text.contains("Review."));
        std::fs::write(&edited, text.replace("Review.", "My edit.")).unwrap();
        let manifest = manifest::load_current(&root.join(file)).unwrap().unwrap();
        let refused = absorb_ops(
            &env,
            &scope,
            &manifest,
            ItemKind::Agent,
            "rev",
            HarnessId::Claude,
            &edited,
        )
        .unwrap_err();
        let CoreError::ForkWidensAccess { problem, .. } = refused else {
            panic!("expected the catalog-settings refusal")
        };
        assert_eq!(
            problem,
            format!("its catalog settings would have to be written to {file} first")
        );
        if catalog {
            assert!(!problem.contains("kendex.toml"));
        }
    }
}
