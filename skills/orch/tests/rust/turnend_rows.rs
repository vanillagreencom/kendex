//! Process tests of a session's own event rows written at its turn end: a
//! session with no lane item, a Pi lane's turn and a managed Jarvis
//! session. Every row runs the real `orch-runtime turn-end` in a
//! [`support::TurnWorld`].
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant records and read the answer of the binary they start"
)]

#[path = "support.rs"]
mod support;

use std::fs;

use serde_json::json;
use support::*;

const PANE: &str = "%3";
const SESSION: &str = "native-1";

/// A managed Jarvis session on the pane `TMUX_PANE` names, where the server
/// `$TMUX` names does not answer, has no key its record's stamp could carry:
/// its turn end and its tool call each tell `jarvis-rows-unwritten` with the
/// pane left unkeyed, its row tells `rows-unwritten` with the same cause,
/// and the record takes no stamp. Outside tmux nothing is told.
#[test]
fn a_jarvis_session_whose_server_does_not_answer_tells_its_rows_unwritten() {
    let world = TurnWorld::new();
    let account = world.root.join("accounts/claude-1");
    fs::create_dir_all(&account).unwrap();
    let session = world.jarvis_session(PANE, "claude", SESSION, "4", &account);
    let record = world.plant_jarvis(&world.checkout, session);
    let planted = fs::read_to_string(&record).unwrap();
    // A socket the stand-in serves no server on.
    let refused = world.root.join("no-server");
    let env = [
        ("TMUX".to_owned(), format!("{},1,0", refused.display())),
        ("TMUX_PANE".to_owned(), PANE.to_owned()),
        (
            "CLAUDE_CONFIG_DIR".to_owned(),
            account.display().to_string(),
        ),
        ("JARVIS_RECORD".to_owned(), record.display().to_string()),
        ("JARVIS_GENERATION".to_owned(), "4".to_owned()),
    ];
    let payload = json!({ "session_id": SESSION }).to_string();
    let told = format!("jarvis-rows-unwritten={}", record.display());
    let cause = format!("\npane=unkeyed tmux_pane={PANE}\n");
    for (name, args) in [("turn end", &[][..]), ("tool call", &["halt"][..])] {
        let out = world.turn(&world.checkout, "claude", args, &payload, &env);
        assert_eq!(out.code, 0, "{name}: {}", out.stderr);
        assert_eq!(out.keyed(), [told.as_str()], "{name}: {}", out.stderr);
        assert!(out.stderr.contains(&cause), "{name}: {}", out.stderr);
        let standing = fs::read_to_string(&record).unwrap();
        assert_eq!(standing, planted, "{name}: the record took a stamp");
    }
    // Its row tells its session row unwritten, ahead of the box check.
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
    assert_eq!(
        fs::read_to_string(&record).unwrap(),
        planted,
        "row: a stamp"
    );
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
    let out = world.turn(&world.checkout, "claude", &[], &payload, &outside);
    assert_eq!(out.code, 0, "outside tmux: {}", out.stderr);
    assert!(out.keyed().is_empty(), "outside tmux: {}", out.stderr);
}
