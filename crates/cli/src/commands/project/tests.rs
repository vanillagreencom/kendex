use std::path::{Path, PathBuf};

use kendex_core::model::ItemKind;
use kendex_core::scan::MissingWhy;
use kendex_core::settings::{Confirm, Relocation, Standing};

use super::*;
use crate::ui::testing::{plain, rich, tagged};
use crate::width::visible_width;

/// Every state a listed folder can be in, plain as scripts read it.
#[test]
fn project_list_rows_keep_their_plain_line() {
    let folder = Path::new("/dev/app-lane");
    let cases = [
        (Listed::Folder, "/dev/app-lane"),
        (
            Listed::Worktree(Linked {
                main: Some(PathBuf::from("/dev/app")),
            }),
            "/dev/app-lane  (worktree of /dev/app)",
        ),
        (
            Listed::Worktree(Linked { main: None }),
            "/dev/app-lane  (worktree)",
        ),
        (
            Listed::Missing(MissingWhy::Gone),
            "/dev/app-lane  (folder not found)",
        ),
        (
            Listed::Missing(MissingWhy::NotAFolder),
            "/dev/app-lane  (not a folder)",
        ),
        (
            Listed::Missing(MissingWhy::Unreadable {
                said: "permission denied".to_owned(),
            }),
            "/dev/app-lane  (folder could not be read)",
        ),
    ];
    for (state, line) in cases {
        assert_eq!(listed_row(&plain(), folder, &state), [line]);
    }
}

/// A folder that is not there blocks every write into it: rich draws it
/// as a failure, and a readable one as a notice.
#[test]
fn project_list_rows_rich() {
    let folder = Path::new("/dev/app");
    assert_eq!(
        tagged(&listed_row(&rich(80), folder, &Listed::Folder)),
        ["  <36>•</> /dev/app"]
    );
    assert_eq!(
        tagged(&listed_row(
            &rich(80),
            folder,
            &Listed::Missing(MissingWhy::Gone)
        )),
        ["  <31>✗</> /dev/app (folder not found)"]
    );
}

fn offers() -> Vec<Offer> {
    vec![
        Offer {
            kind: ItemKind::Skill,
            name: "tidy".to_owned(),
            harnesses: vec!["claude", "codex"],
            tools: vec!["Claude Code", "Codex"],
        },
        Offer {
            kind: ItemKind::Agent,
            name: "review".to_owned(),
            harnesses: vec!["claude"],
            tools: vec!["Claude Code"],
        },
    ]
}

/// The offer is a decision: its plain lines stay the runnable commands
/// scripts and people copy.
#[test]
fn unmanaged_offer_snapshots() {
    let root = Path::new("/dev/my app");
    assert_eq!(
        offer_lines(&plain(), root, &offers()),
        [
            "2 packages here are not managed by kendex yet:",
            "  - skill tidy [Claude Code, Codex]  (cd '/dev/my app' && kendex adopt skill tidy --harness claude --harness codex)",
            "  - agent review [Claude Code]  (cd '/dev/my app' && kendex adopt agent review --harness claude)",
        ]
    );
    assert_eq!(
        tagged(&offer_lines(&rich(100), root, &offers()[1..])),
        [
            "  <33>!</> 1 package here is not managed by kendex yet:",
            "    <90>agent review [Claude Code] (cd '/dev/my app' && kendex adopt agent review --harness claude)</>",
        ]
    );
    assert!(offer_lines(&plain(), root, &[]).is_empty());
}

/// A narrow terminal wraps the prose and never breaks the command.
#[test]
fn unmanaged_offer_keeps_its_command_whole() {
    let root = Path::new("/dev/app");
    let drawn = offer_lines(&rich(40), root, &offers());
    let command = "cd '/dev/app' && kendex adopt skill tidy --harness claude --harness codex";
    assert!(drawn.iter().any(|line| line.contains(command)), "{drawn:?}");
    assert!(
        drawn
            .iter()
            .filter(|line| !line.contains("kendex adopt"))
            .all(|line| visible_width(line) <= 40),
        "{drawn:?}"
    );
}

/// The registry outcomes: what was done to which folder.
#[test]
fn registry_outcome_snapshots() {
    let folder = Path::new("/dev/app");
    assert_eq!(
        folder_line(&plain(), Status::Done, "registered ", folder, ""),
        ["registered /dev/app"]
    );
    assert_eq!(
        tagged(&folder_line(
            &rich(80),
            Status::Done,
            "added ",
            folder,
            " to your projects"
        )),
        ["  <32>✓</> added /dev/app to your projects"]
    );
    let moved = Relocation {
        from: PathBuf::from("/old/app"),
        to: PathBuf::from("/new/app"),
        standing: Standing::Registered,
        confirm: Confirm::Consolidate,
    };
    assert_eq!(
        reconnected(&plain(), &moved),
        ["/old/app is now at /new/app  (joined with the project already listed there)"]
    );
    assert_eq!(
        found(
            &plain(),
            &[PathBuf::from("/dev/a"), PathBuf::from("/dev/b")]
        ),
        ["/dev/a", "/dev/b"]
    );
    let long = PathBuf::from(format!(
        "/home/dev/My Projects/{}app",
        "projects/".repeat(8)
    ));
    assert_eq!(
        tagged(&found(&rich(80), std::slice::from_ref(&long))),
        [
            "".to_owned(),
            "<1;36>projects found</>  <90>1</>".to_owned(),
            "  <1;90>folder</>".to_owned(),
            format!("  <90>{}</>", "─".repeat(97)),
            format!("  {}", long.display()),
        ]
    );
}

/// A folder name off the disk cannot move the cursor or split the line.
#[test]
fn registry_outcome_escapes_the_folder() {
    let folder = Path::new("/dev/a\u{7}b\u{202e}c\nd");
    for style in [plain(), rich(80)] {
        let drawn = folder_line(&style, Status::Done, "registered ", folder, "");
        assert_eq!(drawn.len(), 1, "{drawn:?}");
        for raw in ['\u{7}', '\u{202e}', '\n'] {
            assert!(
                !drawn[0].contains(raw),
                "{raw:?} reached the line: {drawn:?}"
            );
        }
    }
}
