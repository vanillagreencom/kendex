//! Consumer agent renders and verify deliver the same run-wide model notice.

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
    for name in ["fast", "another-fast"] {
        fs::write(
            catalog.join(format!("agents/{name}.md")),
            format!(
                "---\nname: {name}\ndescription: Fast worker\nmodel: haiku\n---\nDo the work.\n"
            ),
        )
        .unwrap();
    }
    fs::write(
        project.join("kendex.toml"),
        format!(
            "{}\n[agents.another-fast]\nsource = \"cat\"\n",
            agent_manifest(&catalog, Some("fast"))
        ),
    )
    .unwrap();
    for args in [
        vec!["refresh", "--scope", "project", "--yes", "--leave"],
        vec!["verify", "--scope", "project"],
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
            .filter(|line| line.contains("lane-model:"))
            .collect();
        assert_eq!(
            warnings,
            ["lane-model: requested=haiku resolved=sonnet; KEN-2466 removes this substitution"],
            "{args:?}: {stderr}"
        );
        for name in ["fast", "another-fast"] {
            let rendered =
                fs::read_to_string(project.join(format!(".claude/agents/{name}.md"))).unwrap();
            let parsed = kendex_core::render::agent::parse_source_agent(&rendered).unwrap();
            assert_eq!(parsed.model, "sonnet", "{args:?}/{name}");
        }
    }
}
