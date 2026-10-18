//! Pi role defaults use the consumer's expanded agent declarations.

use std::fs;

use crate::test_util::{rooted, source_path};
use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

#[test]
#[allow(clippy::unwrap_used)]
fn pi_engineer_defaults_only_delegate_to_installed_agents() {
    for (declaration, override_value, expected) in [
        ("", "", None),
        ("[agents.scout]\nsource = 'cat'\n", "", Some("scout")),
        ("[bundles.team]\nsource = 'cat'\n", "", Some("scout")),
        (
            "[agents.scout]\nsource = 'cat'\nenabled = false\n",
            "",
            None,
        ),
        (
            "[agents.scout]\nsource = 'cat'\nharnesses = ['claude']\n",
            "",
            None,
        ),
        (
            "",
            "allowed-subagents = ['probe', 'scout']",
            Some("probe, scout"),
        ),
        (
            "[agents.scout]\nsource = 'cat'\n",
            "allowed-subagents = []",
            None,
        ),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let catalog = home.join("catalog");
        let project = home.join("consumer");
        fs::create_dir_all(catalog.join("agents")).unwrap();
        fs::create_dir_all(&project).unwrap();
        fs::write(
            catalog.join("kendex.toml"),
            "is_source_catalog = true\n[bundles.team]\nagents = ['scout']\n",
        )
        .unwrap();
        for name in ["iced", "maintainer", "rust", "runtime", "scout"] {
            fs::write(
                catalog.join(format!("agents/{name}.md")),
                format!("---\nname: {name}\ndescription: Test agent\nrole: engineer\n---\nBody.\n"),
            )
            .unwrap();
        }
        let mut manifest = format!(
            "schema = 7\n[install]\nharnesses = ['pi']\n[sources.cat]\n{}\n{declaration}",
            source_path(&catalog)
        );
        for name in ["iced", "maintainer", "rust", "runtime"] {
            manifest.push_str(&format!("[agents.{name}]\nsource = 'cat'\n"));
            if !override_value.is_empty() {
                manifest.push_str(&format!(
                    "[agent-frontmatter.pi.{name}]\n{override_value}\n"
                ));
            }
        }
        fs::write(project.join("kendex.toml"), manifest).unwrap();
        let env = Env::fake(&home, FakeOs::Linux);
        let scope = Scope::Project {
            root: project.clone(),
        };
        let report = audit(&env, &scope).unwrap();
        assert!(report.refused.is_empty());
        apply::execute(&env, &report.plan).unwrap();
        for name in ["iced", "maintainer", "rust", "runtime"] {
            let rendered =
                fs::read_to_string(project.join(format!(".pi/agents/{name}.md"))).unwrap();
            let (frontmatter, _) = kendex_core::frontmatter::split(&rendered).unwrap();
            let frontmatter = kendex_core::frontmatter::parse_tolerant(frontmatter)
                .unwrap()
                .map;
            assert_eq!(
                frontmatter
                    .get("allowed-subagents")
                    .and_then(|value| value.as_str()),
                expected
            );
            let denies = frontmatter.get("deny-tools").unwrap().as_str().unwrap();
            assert_eq!(
                denies.split(", ").any(|tool| tool == "delegate_subagent"),
                expected.is_none()
            );
        }
    }
}
