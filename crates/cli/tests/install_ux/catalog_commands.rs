//! Every catalog command installs through the CLI with its prompt intact.

use crate::{World, read};
use kendex_core::frontmatter;
use kendex_core::harness::installs_here;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::render::agent::GENERATED_BANNER;

/// Each command this repository ships, with the number of paragraphs its
/// prompt is written to hold. The floor below keeps this list equal to
/// `commands/`, so a new command cannot ship without a row here.
const COMMANDS: [(&str, usize); 2] = [("code-scrub", 2), ("npm-deploy", 2)];

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
    let mut named: Vec<String> = COMMANDS
        .iter()
        .map(|(name, _)| (*name).to_owned())
        .collect();
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
    assert_eq!(
        [
            HarnessId::Claude,
            HarnessId::Codex,
            HarnessId::Opencode,
            HarnessId::Pi,
            HarnessId::Gemini,
        ]
        .as_slice(),
        supported,
        "the output table must cover the command capability table"
    );

    for (command, paragraphs) in COMMANDS {
        world.run(&["add", "cat", "--command", command, "--all-harnesses", "-y"]);

        let source = read(&world.catalog.join(format!("commands/{command}.md")));
        let (_, expected) = frontmatter::split(&source).unwrap();
        let outputs = [
            (HarnessId::Claude, format!(".claude/commands/{command}.md")),
            (
                HarnessId::Codex,
                format!(".agents/skills/{command}/SKILL.md"),
            ),
            (
                HarnessId::Opencode,
                format!(".opencode/commands/{command}.md"),
            ),
            (HarnessId::Pi, format!(".pi/prompts/{command}.md")),
            (
                HarnessId::Gemini,
                format!(".gemini/commands/{command}.toml"),
            ),
        ];
        for (harness, path) in outputs {
            let rendered = read(&world.at(&path));
            let prompt = if harness == HarnessId::Gemini {
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
            assert_eq!(
                prompt.trim().split("\n\n").count(),
                paragraphs,
                "{path}: count prompt paragraphs after removing format metadata"
            );
        }
    }
}
