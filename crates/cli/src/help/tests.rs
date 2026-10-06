use std::collections::BTreeMap;
use std::path::PathBuf;

use super::*;

#[test]
fn shared_kind_parser_keeps_canonical_names_and_existing_aliases() {
    use crate::commands::pin::parse_kind;
    use kendex_core::model::ItemKind;

    for (value, kind) in [
        ("agent", ItemKind::Agent),
        ("agents", ItemKind::Agent),
        ("a", ItemKind::Agent),
        ("skill", ItemKind::Skill),
        ("skills", ItemKind::Skill),
        ("s", ItemKind::Skill),
        ("hook", ItemKind::Hook),
        ("hooks", ItemKind::Hook),
        ("command", ItemKind::Command),
        ("commands", ItemKind::Command),
        ("mcp-server", ItemKind::McpServer),
        ("mcp", ItemKind::McpServer),
        ("pi-extension", ItemKind::PiExtension),
        ("pi", ItemKind::PiExtension),
        ("output-style", ItemKind::OutputStyle),
    ] {
        assert_eq!(parse_kind(value), Ok(kind), "{value}");
    }
    for value in [
        "plugin",
        "plugins",
        "output-styles",
        "style",
        "h",
        "",
        "Output-style",
    ] {
        assert_eq!(
            parse_kind(value),
            Err(format!(
                "unknown kind '{value}' (agent | skill | hook | command | mcp-server | pi-extension | output-style)"
            )),
            "{value}"
        );
    }
}

/// The kinds `--kind` on enable, disable and remove names in its help and
/// its unknown-kind error are every kind, plugin and output style
/// included, and each one it names parses.
#[test]
fn kind_or_plugin_choices_are_every_kind_the_parser_takes() {
    use crate::commands::pin::{kind_or_plugin_choices, parse_kind_or_plugin};
    use kendex_core::model::ItemKind;

    let named: Vec<String> = kind_or_plugin_choices()
        .split(" | ")
        .map(str::to_owned)
        .collect();
    for kind in ItemKind::ALL {
        assert!(
            named.contains(&kind.name().to_owned()),
            "{kind:?}: {named:?}"
        );
        assert_eq!(parse_kind_or_plugin(kind.name()), Ok(kind), "{kind:?}");
    }
    let refused = parse_kind_or_plugin("plugins").unwrap_err();
    let (_, listed) = refused
        .split_once('(')
        .and_then(|(head, rest)| Some((head, rest.strip_suffix(')')?)))
        .unwrap_or_else(|| panic!("the error lists no kinds: {refused}"));
    assert_eq!(listed.split(" | ").collect::<Vec<_>>(), named, "{refused}");
}

fn pages() -> BTreeMap<String, String> {
    fn visit(mut command: Command, path: &str, pages: &mut BTreeMap<String, String>) {
        command = command
            .bin_name(path)
            .term_width(80)
            .color(clap::ColorChoice::Never);
        command.build();
        pages.insert(
            path.replace(' ', "-"),
            command.render_long_help().to_string(),
        );
        for child in command
            .get_subcommands()
            .filter(|child| child.get_name() != "help")
        {
            visit(
                child.clone(),
                &format!("{path} {}", child.get_name()),
                pages,
            );
        }
    }
    let mut pages = BTreeMap::new();
    visit(command(), "kendex", &mut pages);
    pages
}

fn directory() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/snapshots/help")
}

/// The issue requests wording snapshots as well as the order and grouping.
/// Discovery comes from the same Clap tree dispatch parses. A missing file
/// fails, and stale files fail the reverse inventory comparison.
#[test]
#[allow(clippy::unwrap_used)]
fn every_command_has_a_help_snapshot() {
    let pages = pages();
    assert!(pages.len() >= 30, "command-tree discovery is incomplete");
    assert!(
        pages.contains_key("kendex-report"),
        "hidden commands were skipped"
    );
    assert!(
        !pages.contains_key("kendex-help-help"),
        "generated help commands entered dispatch discovery"
    );
    for (name, actual) in &pages {
        let path = directory().join(format!("{name}.txt"));
        let expected = std::fs::read_to_string(&path).unwrap();
        assert_eq!(*actual, expected, "{}", path.display());
        let opening = actual.lines().next().unwrap();
        assert!(
            !opening.is_empty() && !opening.starts_with("Usage:"),
            "{name}"
        );
        assert!(actual.contains("\nUsage: "), "{name}");
    }
    let recorded: std::collections::BTreeSet<_> = std::fs::read_dir(directory())
        .unwrap()
        .map(|entry| {
            entry
                .unwrap()
                .path()
                .file_stem()
                .unwrap()
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    assert_eq!(recorded, pages.into_keys().collect());
}

#[test]
#[ignore = "writes the reviewed help snapshots after a command help change"]
#[allow(clippy::unwrap_used)]
fn regenerate_help_snapshots() {
    std::fs::create_dir_all(directory()).unwrap();
    for (name, help) in pages() {
        std::fs::write(directory().join(format!("{name}.txt")), help).unwrap();
    }
}
