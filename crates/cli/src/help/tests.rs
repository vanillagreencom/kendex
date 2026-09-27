use std::collections::BTreeMap;
use std::path::PathBuf;

use super::*;

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
