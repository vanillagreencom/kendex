//! Every catalog command installs through the CLI with its prompt intact.

use crate::{World, read};
use kendex_core::frontmatter;
use kendex_core::harness::installs_here;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::render::agent::GENERATED_BANNER;

/// Each command this repository ships. The floor below keeps this list
/// equal to `commands/`, so a new command cannot ship without a row here.
const COMMANDS: &[&str] = &["code-scrub", "npm-deploy"];

/// Where each harness that takes commands writes one, with `{command}`
/// standing in for the command's name. This is the only harness list: the
/// capability assertion below reads its first column, so a harness whose
/// render goes unread cannot be claimed as covered.
const OUTPUTS: &[(HarnessId, &str)] = &[
    (HarnessId::Claude, ".claude/commands/{command}.md"),
    (HarnessId::Codex, ".agents/skills/{command}/SKILL.md"),
    (HarnessId::Opencode, ".opencode/commands/{command}.md"),
    (HarnessId::Pi, ".pi/prompts/{command}.md"),
    (HarnessId::Gemini, ".gemini/commands/{command}.toml"),
];

#[test]
#[allow(clippy::unwrap_used)]
fn catalog_commands_install_in_every_supported_harness_with_their_prompts_intact() {
    let mut world = World::new(&[]);
    // This repository, not a fixture catalog: the promise is about the
    // package as shipped, so the source has to be the real `commands/`
    // beside the real `kendex.toml` rather than a copy of either.
    world.catalog = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap();
    world.declare_catalog();

    let mut shipped: Vec<String> = std::fs::read_dir(world.catalog.join("commands"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "md"))
        .map(|path| path.file_stem().unwrap().to_string_lossy().into_owned())
        .collect();
    shipped.sort();
    let mut named: Vec<String> = COMMANDS.iter().map(|name| (*name).to_owned()).collect();
    named.sort();
    assert_eq!(
        shipped, named,
        "every file under commands/ needs a row in COMMANDS"
    );

    let supported: Vec<_> = HarnessId::ALL
        .into_iter()
        .filter(|harness| {
            installs_here(
                *harness,
                ItemKind::Command,
                &Scope::Project {
                    root: world.project.clone(),
                },
            )
        })
        .collect();
    let covered: Vec<_> = OUTPUTS.iter().map(|(harness, _)| *harness).collect();
    assert_eq!(
        covered, supported,
        "the output table must cover the command capability table"
    );

    for command in COMMANDS {
        world.run(&["add", "cat", "--command", command, "--all-harnesses", "-y"]);

        let source = read(&world.catalog.join(format!("commands/{command}.md")));
        let (_, expected) = frontmatter::split(&source).unwrap();
        for (harness, template) in OUTPUTS {
            let path = template.replace("{command}", command);
            let rendered = read(&world.at(&path));
            // Gemini's own placeholder, through the renderer's translation
            // rather than a second spelling of it here.
            let expected = if *harness == HarnessId::Gemini {
                kendex_core::render::command::gemini_prompt(expected)
            } else {
                expected.to_owned()
            };
            let prompt = if *harness == HarnessId::Gemini {
                let table: toml::Table = rendered.parse().unwrap();
                table["prompt"].as_str().unwrap().to_owned()
            } else {
                let (_, body) = frontmatter::split(&rendered).unwrap();
                body.trim()
                    .strip_prefix(GENERATED_BANNER)
                    .unwrap_or(body)
                    .trim()
                    .to_owned()
            };
            assert_eq!(prompt.trim(), expected.trim(), "{path}");
        }
    }
}
