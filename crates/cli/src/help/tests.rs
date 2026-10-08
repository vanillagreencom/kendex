use std::collections::BTreeMap;

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

fn commands() -> BTreeMap<String, Command> {
    fn visit(mut command: Command, path: &str, commands: &mut BTreeMap<String, Command>) {
        command.build();
        for child in command
            .get_subcommands()
            .filter(|child| child.get_name() != "help")
        {
            visit(
                child.clone(),
                &format!("{path} {}", child.get_name()),
                commands,
            );
        }
        assert!(commands.insert(path.to_owned(), command).is_none());
    }
    let mut commands = BTreeMap::new();
    visit(command(), "kendex", &mut commands);
    commands
}

#[test]
fn command_tree_keeps_help_and_adopt_argument_contracts() {
    let commands = commands();
    assert!(commands.len() >= 30, "command-tree discovery is incomplete");
    assert!(
        commands.contains_key("kendex report"),
        "hidden commands were skipped"
    );
    assert!(
        !commands.contains_key("kendex help help"),
        "generated help commands entered dispatch discovery"
    );
    assert!(commands["kendex report"].is_hide_set());
    for (path, command) in &commands {
        command.clone().debug_assert();
        let error = command
            .clone()
            .try_get_matches_from([path.as_str(), "--help"])
            .expect_err("--help must return help without dispatching");
        assert_eq!(error.kind(), clap::error::ErrorKind::DisplayHelp, "{path}");
    }

    let adopt = &commands["kendex adopt"];
    for (id, index, long, required, action) in [
        ("kind", Some(1), None, true, clap::ArgAction::Set),
        ("name", Some(2), None, true, clap::ArgAction::Set),
        (
            "harness",
            None,
            Some("harness"),
            false,
            clap::ArgAction::Append,
        ),
        (
            "global",
            None,
            Some("global"),
            false,
            clap::ArgAction::SetTrue,
        ),
        ("scope", None, Some("scope"), false, clap::ArgAction::Set),
    ] {
        let arg = adopt
            .get_arguments()
            .find(|arg| arg.get_id() == id)
            .expect("adopt argument must exist");
        assert_eq!(arg.get_index(), index, "{id}");
        assert_eq!(arg.get_long(), long, "{id}");
        assert_eq!(arg.is_required_set(), required, "{id}");
        assert_eq!(
            std::mem::discriminant(arg.get_action()),
            std::mem::discriminant(&action),
            "{id}"
        );
    }
}
