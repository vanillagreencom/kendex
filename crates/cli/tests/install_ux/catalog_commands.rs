//! Every catalog command installs through the CLI with its prompt intact.

use crate::{World, read};
use kendex_core::frontmatter;
use kendex_core::harness::{installs_here, rendered_name};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::render::agent::GENERATED_BANNER;

/// Each command this repository ships. The floor below keeps this list
/// equal to `commands/`, so a new command cannot ship without a row here.
const COMMANDS: &[&str] = &["code-scrub"];

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

    let mut shipped = command_stems(&world.catalog.join("commands"), None);
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
            let path = template.replace("{command}", &rendered_name(*harness, command));
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

/// The command names a directory holds, the way the catalog reader counts
/// them: every `.md` file at the top level, and every one a single segment
/// down named `<parent>/<leaf>`. A namespaced command installs, so a floor
/// that read only the top level would let one ship with no row in
/// `COMMANDS` and no harness check.
#[allow(clippy::unwrap_used)]
fn command_stems(dir: &std::path::Path, parent: Option<&str>) -> Vec<String> {
    let mut names = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|ext| ext == "md") {
            let stem = path.file_stem().unwrap().to_string_lossy().into_owned();
            names.push(match parent {
                Some(parent) => format!("{parent}/{stem}"),
                None => stem,
            });
        } else if path.is_dir() && parent.is_none() {
            let child = path.file_name().unwrap().to_string_lossy().into_owned();
            // A kind dir's support directories hold the items' own suites
            // and fixtures, which the catalog reader skips for the same
            // reason: files there are about the commands, not commands.
            if !matches!(child.as_str(), "tests" | "test" | "fixtures" | "testdata") {
                names.extend(command_stems(&path, Some(&child)));
            }
        }
    }
    names
}
