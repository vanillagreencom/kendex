//! Process tests of a session's own event rows written at its turn end: a
//! session with no lane item. Every row runs the real `orch-runtime
//! turn-end` in a [`support::TurnWorld`].
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant records and read the answer of the binary they start"
)]

#[path = "support.rs"]
mod support;

use serde_json::json;
use support::*;

const PANE: &str = "%3";
const SESSION: &str = "native-1";

/// A session on the pane `TMUX_PANE` names, where the server `$TMUX` names
/// does not answer, has no key its row could carry: its row tells
/// `rows-unwritten` with the pane left unkeyed, ahead of the box check, and
/// its turn end and its tool call tell nothing. Outside tmux nothing is
/// told.
#[test]
fn a_session_whose_server_does_not_answer_tells_its_row_unwritten() {
    let world = TurnWorld::new();
    let account = world.root.join("accounts/claude-1");
    std::fs::create_dir_all(&account).unwrap();
    // A socket the stand-in serves no server on.
    let refused = world.root.join("no-server");
    let env = [
        ("TMUX".to_owned(), format!("{},1,0", refused.display())),
        ("TMUX_PANE".to_owned(), PANE.to_owned()),
        (
            "CLAUDE_CONFIG_DIR".to_owned(),
            account.display().to_string(),
        ),
    ];
    let payload = json!({ "session_id": SESSION }).to_string();
    let cause = format!("\npane=unkeyed tmux_pane={PANE}\n");
    for (name, args) in [("turn end", &[][..]), ("tool call", &["halt"][..])] {
        let out = world.turn(&world.checkout, "claude", args, &payload, &env);
        assert_eq!(out.code, 0, "{name}: {}", out.stderr);
        assert!(out.keyed().is_empty(), "{name}: {}", out.stderr);
    }
    let overseer = world.checkout.join("tmp/lane-mail/overseer");
    let boxed = overseer.exists();
    let out = world.turn(
        &world.checkout,
        "claude",
        &["row", "SessionStart"],
        &payload,
        &env,
    );
    let rows = format!("rows-unwritten={}", world.checkout.display());
    assert_eq!(out.code, 0, "row: {}", out.stderr);
    assert_eq!(out.keyed(), [rows.as_str()], "row: {}", out.stderr);
    assert!(out.stderr.contains(&cause), "row: {}", out.stderr);
    assert_eq!(overseer.exists(), boxed, "row: the box changed");
    let calls = world.tmux_calls();
    assert!(
        !calls.is_empty()
            && calls
                .iter()
                .all(|call| call == "display-message -p #{pid} #{start_time}"),
        "{calls:?}"
    );
    // Outside tmux a named pane keys nothing either, and nothing is told.
    let outside: Vec<_> = env
        .iter()
        .filter(|(name, _)| name != "TMUX")
        .cloned()
        .collect();
    let out = world.turn(
        &world.checkout,
        "claude",
        &["row", "SessionStart"],
        &payload,
        &outside,
    );
    assert_eq!(out.code, 0, "outside tmux: {}", out.stderr);
    assert!(out.keyed().is_empty(), "outside tmux: {}", out.stderr);
}
