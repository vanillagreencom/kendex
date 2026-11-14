//! Consumer writes, template installs and verify deliver one renderer
//! model notice, and verify lists an installed package's other warnings
//! with their fix and diagnostic line.

use std::fs;
use std::process::Command;

use crate::test_util::{agent_manifest, fixture_env, rooted};

#[test]
#[allow(clippy::unwrap_used)]
fn exact_pin_renders_haiku_and_reports_one_warning_per_process() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("consumer");
    let catalog = home.join("catalog");
    fs::create_dir_all(&project).unwrap();
    // A tool on this machine, so a template has somewhere to install to.
    fs::create_dir_all(home.join(".claude")).unwrap();
    let installed = home.join("installed");
    let added = home.join("added");
    fs::create_dir_all(&installed).unwrap();
    fs::create_dir_all(&added).unwrap();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    for (name, model) in [
        ("fast", "claude-haiku-5-5"),
        ("another-fast", "claude-haiku-5-5"),
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
    // A skill whose link leaves the project: a warning verify reads off
    // every installation of it.
    fs::create_dir_all(catalog.join("skills/linked")).unwrap();
    fs::write(
        catalog.join("skills/linked/SKILL.md"),
        "---\nname: linked\ndescription: Linked\n---\n[x](../../memory/x.md)\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "{}\n[agents.another-fast]\nsource = \"cat\"\n[agents.removable]\nsource = \"cat\"\n[skills.linked]\nsource = \"cat\"\n",
            agent_manifest(&catalog, Some("fast"))
        ),
    )
    .unwrap();
    let run = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_kendex"))
            .args(args)
            .current_dir(&project)
            .env_clear()
            .envs(fixture_env(&home))
            .env("PATH", std::env::var_os("PATH").unwrap())
            .env("KENDEX_UI", "plain")
            .env("KENDEX_BACKGROUND_REFRESH", "off")
            .output()
            .unwrap()
    };
    let catalog_path = catalog.to_str().unwrap();
    // A template installs its agent through renders it runs itself, which
    // no report presenter sees.
    let saved = run(&[
        "template",
        "create",
        "Fast",
        "--source",
        catalog_path,
        "--agent",
        "fast",
    ]);
    assert!(saved.status.success(), "{saved:?}");
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
        vec![
            "template",
            "install",
            "Fast",
            "--project",
            installed.to_str().unwrap(),
            "--yes",
        ],
        vec![
            "project",
            "add",
            added.to_str().unwrap(),
            "--template",
            "Fast",
            "--yes",
        ],
    ] {
        let output = run(&args);
        assert!(output.status.success(), "{args:?}: {output:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        if args[0] == "verify" {
            assert!(
                stderr
                    .lines()
                    .any(|line| line == "  agent-link-unrepresentable: ../../memory/x.md"),
                "{args:?}: {stderr}"
            );
        }
        let warnings: Vec<_> = stderr
            .lines()
            .filter(|line| line.starts_with("model-resolution:"))
            .collect();
        assert_eq!(
            warnings,
            [
                "model-resolution: requested=claude-haiku-5-5 selected=claude-haiku-5-5 causes=old-id source="
            ],
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
                Some("claude-haiku-5-5"),
                "{args:?}/{name}"
            );
        }
    }
}
