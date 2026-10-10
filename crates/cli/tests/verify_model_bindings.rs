//! Native class bindings and unbound agents verify through the same render owner.
#![cfg(unix)]

use super::verify_records::{kendex, said, write};
use crate::test_util::{rooted, source_path};
use std::fs;

#[test]
fn bound_and_unbound_class_agents_verify_after_apply() {
    for bound in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = home.join("consumer");
        let catalog = home.join("catalog");
        // A catalog binding is not the consumer's model policy.
        write(
            &catalog.join("kendex.toml"),
            "is_source_catalog = true\nmodel-bindings.codex.standard = 'catalog-model'\nmodel-bindings.copilot.standard = 'catalog-model'\n",
        );
        write(
            &catalog.join("agents/worker.md"),
            "---\nname: worker\ndescription: Work\nmodel: standard\n---\nBody.\n",
        );
        let bindings = if bound {
            "[model-bindings.codex]\nstandard = 'gpt-6.1-sol'\n[model-bindings.copilot]\nstandard = 'claude-opus-4.6'\n"
        } else {
            ""
        };
        write(
            &project.join("kendex.toml"),
            &format!(
                "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = ['codex', 'copilot']\nmethod = 'copy'\n[agents.worker]\nsource = 'cat'\n{bindings}",
                source_path(&catalog)
            ),
        );
        let applied = kendex(&home, &project, &["apply", "-y", "--leave"]);
        assert!(
            applied.status.success(),
            "bound={bound}: {}",
            said(&applied)
        );
        let codex = fs::read_to_string(project.join(".codex/agents/worker.toml"))
            .unwrap()
            .parse::<toml::Table>()
            .unwrap();
        assert_eq!(
            codex.get("model").and_then(toml::Value::as_str),
            bound.then_some("gpt-6.1-sol")
        );
        let copilot = fs::read_to_string(project.join(".github/agents/worker.agent.md")).unwrap();
        assert_eq!(
            copilot.lines().find(|line| line.starts_with("model:")),
            bound.then_some("model: claude-opus-4.6")
        );
        let verified = kendex(&home, &project, &["verify", "--scope", "project", "--json"]);
        assert_eq!(
            verified.status.code(),
            Some(0),
            "bound={bound}: {}",
            said(&verified)
        );
        if bound {
            fs::write(
                project.join(".codex/agents/worker.toml"),
                fs::read_to_string(project.join(".codex/agents/worker.toml"))
                    .unwrap()
                    .replace("gpt-6.1-sol", "gpt-6-astra"),
            )
            .unwrap();
            let changed = kendex(&home, &project, &["verify", "--scope", "project", "--json"]);
            assert_ne!(
                changed.status.code(),
                Some(0),
                "edited binding must fail verification"
            );
        }
    }
}
