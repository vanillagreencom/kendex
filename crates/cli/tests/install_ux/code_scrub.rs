//! The catalog command installs through the CLI with its prompt intact.

use crate::{World, read};
use kendex_core::frontmatter;
use kendex_core::harness::installs_here;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::render::agent::GENERATED_BANNER;

#[test]
#[allow(clippy::unwrap_used)]
fn code_scrub_installs_in_every_supported_harness_with_two_prompt_paragraphs() {
    let mut world = World::new(&[]);
    // This repository, not a fixture catalog: the promise is about the
    // package as shipped, so the source has to be the real `commands/`
    // beside the real `kendex.toml` rather than a copy of either.
    world.catalog = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap();
    world.declare_catalog();
    world.run(&[
        "add",
        "cat",
        "--command",
        "code-scrub",
        "--all-harnesses",
        "-y",
    ]);

    let source = read(&world.catalog.join("commands/code-scrub.md"));
    let (_, expected) = frontmatter::split(&source).unwrap();
    let outputs = [
        (HarnessId::Claude, ".claude/commands/code-scrub.md"),
        (HarnessId::Codex, ".agents/skills/code-scrub/SKILL.md"),
        (HarnessId::Opencode, ".opencode/commands/code-scrub.md"),
        (HarnessId::Pi, ".pi/prompts/code-scrub.md"),
        (HarnessId::Gemini, ".gemini/commands/code-scrub.toml"),
    ];
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
        outputs.map(|(harness, _)| harness).as_slice(),
        supported,
        "the output table must cover the command capability table"
    );
    for (harness, path) in outputs {
        let rendered = read(&world.at(path));
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
            2,
            "{path}: count prompt paragraphs after removing format metadata"
        );
    }
}
