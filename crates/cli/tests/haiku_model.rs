//! Consumer writes and verify deliver one renderer model notice.

use std::fs;
use std::process::Command;

use crate::test_util::{agent_manifest, fixture_env, rooted};

#[test]
#[allow(clippy::unwrap_used)]
fn haiku_renders_sonnet_and_reports_one_warning_per_process() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("consumer");
    let catalog = home.join("catalog");
    fs::create_dir_all(&project).unwrap();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    for (name, model) in [
        ("fast", "haiku"),
        ("another-fast", "haiku"),
        ("removable", "inherit"),
    ] {
        fs::write(
            catalog.join(format!("agents/{name}.md")),
            format!(
                "---\nname: {name}\ndescription: Fast worker\nmodel: {model}\n---\nDo the work.\n"
            ),
        )
        .unwrap();
    }
    fs::write(
        project.join("kendex.toml"),
        format!(
            "{}\n[agents.another-fast]\nsource = \"cat\"\n[agents.removable]\nsource = \"cat\"\n",
            agent_manifest(&catalog, Some("fast"))
        ),
    )
    .unwrap();
    for args in [
        vec!["source", "enable", "cat", "--scope", "project", "--leave"],
        vec!["refresh", "--scope", "project", "--yes", "--leave"],
        vec!["verify", "--scope", "project"],
        vec![
            "remove",
            "removable",
            "--keep-declaration",
            "--scope",
            "project",
            "--leave",
        ],
        vec!["refresh", "--scope", "project", "--yes", "--leave"],
        vec![
            "remove",
            "removable",
            "--no-sweep",
            "--scope",
            "project",
            "--leave",
        ],
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_kendex"))
            .args(&args)
            .current_dir(&project)
            .env_clear()
            .envs(fixture_env(&home))
            .env("PATH", std::env::var_os("PATH").unwrap())
            .env("KENDEX_UI", "plain")
            .env("KENDEX_BACKGROUND_REFRESH", "off")
            .output()
            .unwrap();
        assert!(output.status.success(), "{args:?}: {output:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        let warnings: Vec<_> = stderr
            .lines()
            .filter(|line| line.starts_with("model-resolution:"))
            .collect();
        assert_eq!(
            warnings,
            ["model-resolution: requested=fast selected=sonnet causes=fallback source="],
            "{args:?}: {stderr}"
        );
        for name in ["fast", "another-fast"] {
            let rendered =
                fs::read_to_string(project.join(format!(".claude/agents/{name}.md"))).unwrap();
            let (yaml, _) = kendex_core::frontmatter::split(&rendered).unwrap();
            let parsed = kendex_core::frontmatter::parse_tolerant(yaml).unwrap();
            assert_eq!(
                parsed
                    .map
                    .get("model")
                    .and_then(kendex_core::frontmatter::Value::as_str),
                Some("sonnet"),
                "{args:?}/{name}"
            );
        }
    }
}
