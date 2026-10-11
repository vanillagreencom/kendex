use super::*;
use crate::manifest::FrontmatterOverrides;
use crate::model::{HarnessId, Scope};
use crate::render::agent::{EffectiveAgent, generate, parse_source_agent};
use crate::render::permission::PermissionIntent;

fn render(
    body: &str,
    harness: HarnessId,
    paths: BodyPaths<'_>,
) -> crate::render::agent::RenderedAgent {
    let source =
        parse_source_agent(&format!("---\nname: a\ndescription: Agent\n---\n{body}")).unwrap();
    let scope = Scope::Project {
        root: paths.install_root.to_path_buf(),
    };
    let agent = EffectiveAgent {
        source: &source,
        harness,
        scope: &scope,
        skills: vec![],
        overrides: FrontmatterOverrides::default(),
        model_classes: Default::default(),
        model_bindings: Default::default(),
        permissions: PermissionIntent::Unspecified,
        launch_instructions: None,
        additional_instructions: None,
        custom_hooks: vec![],
        role_policy: None,
    };
    generate(&agent, Some(paths)).unwrap()
}

#[test]
fn every_harness_rebases_links_and_citations_from_the_catalog_into_the_scope() {
    let body = concat!(
        "[skill](../.agents/skills/s/workflows/w.md#part)\n",
        "[URL](https://example.com/a.md) [absolute](/etc/a.md) [anchor](#anchor)\n",
        "`../.agents/skills/s/workflows/w.md § Part`\n",
        "../.agents/skills/s/workflows/w.md § Part\n",
    );
    let rows = [
        (HarnessId::Claude, ".claude/agents/a.md", "../../"),
        (HarnessId::Copilot, ".github/agents/a.agent.md", "../../"),
        (HarnessId::Pi, ".pi/agents/a.md", "../../"),
        (HarnessId::Codex, ".codex/agents/a.toml", "../../"),
        (HarnessId::Cursor, ".cursor/rules/a.mdc", "../../"),
        (HarnessId::Opencode, ".opencode/agents/a.md", "../../"),
        (HarnessId::Gemini, ".gemini/agents/a.md", "../../"),
        (
            HarnessId::Antigravity,
            ".gemini/config/agents/a.md",
            "../../../",
        ),
    ];
    for catalog in ["/project", "/cache/catalog"] {
        for (harness, file, prefix) in rows {
            let source = Path::new(catalog).join("agents/a.md");
            let rendered = Path::new("/project").join(file);
            let output = render(
                body,
                harness,
                BodyPaths {
                    source: &source,
                    source_root: Path::new(catalog),
                    rendered: &rendered,
                    install_root: Path::new("/project"),
                },
            );
            let expected = body.replace("../.agents", &format!("{prefix}.agents"));
            let actual = if harness == HarnessId::Codex {
                toml::from_str::<toml::Value>(&output.text).unwrap()["developer_instructions"]
                    .as_str()
                    .unwrap()
                    .to_owned()
            } else {
                output.text
            };
            assert!(actual.contains(&expected), "{harness:?}: {actual}");
        }
    }
}

#[test]
fn target_syntax_and_unrepresentable_paths_keep_their_contract() {
    let paths = BodyPaths {
        source: Path::new("/catalog/nested/agents/a.md"),
        source_root: Path::new("/catalog"),
        rendered: Path::new("/home/.config/tool/custom/agents/a.md"),
        install_root: Path::new("/home"),
    };
    let rows = [
        (
            "[s](../../.agents/s.md?view=1#part)",
            "[s](../../../../.agents/s.md?view=1#part)",
            false,
        ),
        (
            "[s][ref]\n\n[ref]: ../../.agents/s.md 'title'\n",
            "[s][ref]\n\n[ref]: ../../../../.agents/s.md 'title'\n",
            false,
        ),
        (
            "![image](../../images/a.png)",
            "![image](../../../../images/a.png)",
            false,
        ),
        ("[s](<../../a b.md>)", "[s](<../../../../a%20b.md>)", false),
        ("[s](../../a%20b.md)", "[s](../../../../a%20b.md)", false),
        ("[s](../../a%23b.md)", "[s](../../../../a%23b.md)", false),
        (
            "[a [b]](../../a\\(b\\).md)",
            "[a [b]](../../../../a\\(b\\).md)",
            false,
        ),
        (
            "[s](<../../a\\>b.md>)",
            "[s](<../../../../a%3Eb.md>)",
            false,
        ),
        ("[a.md#part](#part)", "[a.md#part](#part)", false),
        (
            "[s](%2e%2e/%2e%2e/%2e%2e/a.md)",
            "[s](%2e%2e/%2e%2e/%2e%2e/a.md)",
            true,
        ),
        (
            "[s](../../a\\(b\\).md)",
            "[s](../../../../a\\(b\\).md)",
            false,
        ),
        (
            "[s](https://example.com/a.md) [s](/a.md) [s](#part) [empty]()",
            "[s](https://example.com/a.md) [s](/a.md) [s](#part) [empty]()",
            false,
        ),
        (
            "```md\n[s](../../a.md)\n```\n`[s](../../a.md)`",
            "```md\n[s](../../a.md)\n```\n`[s](../../a.md)`",
            false,
        ),
        (
            "[s](../../../project/a.md)",
            "[s](../../../project/a.md)",
            true,
        ),
        (
            "`../../../project/a.md § Part`",
            "`../../../project/a.md § Part`",
            true,
        ),
    ];
    for (text, expected, warning) in rows {
        let (actual, warnings) = rebase(text, paths);
        assert_eq!(actual, expected);
        assert_eq!(!warnings.is_empty(), warning, "{text}");
    }
    let (actual, warnings) = rebase(
        "[s](../../a.md)",
        BodyPaths {
            rendered: Path::new("/project/.claude/agents/a.md"),
            ..paths
        },
    );
    assert_eq!(actual, "[s](../../a.md)");
    assert!(!warnings.is_empty());
}
