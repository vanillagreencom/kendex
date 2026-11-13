//! Process tests of who a session with no lane item is at its turn end: the
//! controller the fleet record binds, a managed Jarvis session, and the pane
//! a session that lost `TMUX_PANE` recovers. Every row runs the real
//! `orch-runtime turn-end` in a [`support::TurnWorld`].
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant records and read the answer of the binary they start"
)]

#[path = "support.rs"]
mod support;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use serde_json::{Value, json};
use support::*;

const PANE: &str = "%3";
const SESSION: &str = "native-1";

/// A Claude session on the world's pane `pane` with its account directory
/// named, and that directory.
fn claude_on(world: &TurnWorld, pane: &str) -> (Vec<(String, String)>, PathBuf) {
    let account = world.root.join("accounts/claude-1");
    let mut env = world.on_pane(pane);
    env.push((
        "CLAUDE_CONFIG_DIR".to_owned(),
        account.display().to_string(),
    ));
    (env, account)
}

/// A managed Jarvis session of Claude on the world's pane `PANE` whose home
/// is the fleet's checkout: Jarvis's session owner installed there, its pane
/// live in Jarvis's session at generation 4, its running record. The
/// launch's environment, the account directory and the record's path.
fn jarvis_on(world: &TurnWorld) -> (Vec<(String, String)>, PathBuf, PathBuf) {
    let (mut env, account) = claude_on(world, PANE);
    world.install_jarvis(&world.checkout);
    world.plant_pane(PANE, "jarvis", "@7", "4", false);
    let session = world.jarvis_session(PANE, "claude", SESSION, "4", &account);
    let record = world.plant_jarvis(&world.checkout, session);
    env.push(("JARVIS_RECORD".to_owned(), record.display().to_string()));
    env.push(("JARVIS_GENERATION".to_owned(), "4".to_owned()));
    (env, account, record)
}

/// The reads Jarvis's terminal check makes of the pane `PANE`.
fn terminal_reads() -> Vec<String> {
    let mut reads =
        vec!["list-panes -a -F #{pid} #{start_time} #{pane_id} #{pane_dead}".to_owned()];
    for field in ["#{session_name}", "#{window_id}", "#{@jarvis-generation}"] {
        reads.push(format!("display-message -p -t {PANE} {field}"));
    }
    reads
}

/// A turn end of the session `SESSION` from the fleet's checkout.
fn stop(world: &TurnWorld, env: &[(String, String)]) -> TurnOut {
    let payload = json!({ "session_id": SESSION }).to_string();
    world.turn(&world.checkout, "claude", &[], &payload, env)
}

#[test]
fn the_fleet_records_pane_on_its_server_start_names_the_overseer_and_a_native_mismatch_names_none()
{
    // Each case: the member's pane, start and native session, the start the
    // caller's server answers, and whether the turn end heals the record or
    // tells the native mismatch. A held binding is seen by its heal: the
    // record names no native session, which the heal fills from the
    // caller's; a binding that is not held leaves the record as it was.
    struct Case {
        name: &'static str,
        pane: &'static str,
        start: Option<u64>,
        session: &'static str,
        served: u64,
        healed: bool,
        unbound: bool,
    }
    let cases = [
        Case {
            name: "bound on its server's start",
            pane: PANE,
            start: Some(TURN_SERVER_START),
            session: "",
            served: TURN_SERVER_START,
            healed: true,
            unbound: false,
        },
        Case {
            name: "unstarted, its start written",
            pane: PANE,
            start: None,
            session: "",
            served: TURN_SERVER_START,
            healed: true,
            unbound: false,
        },
        Case {
            name: "another pane",
            pane: "%9",
            start: Some(TURN_SERVER_START),
            session: "",
            served: TURN_SERVER_START,
            healed: false,
            unbound: false,
        },
        Case {
            name: "another start of the same pid",
            pane: PANE,
            start: Some(TURN_SERVER_START),
            session: "",
            served: TURN_SERVER_START + 60,
            healed: false,
            unbound: false,
        },
        Case {
            name: "its pane, another native session",
            pane: PANE,
            start: Some(TURN_SERVER_START),
            session: "native-other",
            served: TURN_SERVER_START,
            healed: false,
            unbound: true,
        },
        Case {
            name: "another pane, another native session",
            pane: "%9",
            start: Some(TURN_SERVER_START),
            session: "native-other",
            served: TURN_SERVER_START,
            healed: false,
            unbound: false,
        },
    ];
    for case in cases {
        let world = TurnWorld::new();
        let (env, account) = claude_on(&world, PANE);
        let mut member = world.controller(case.pane, "claude", &account, case.session);
        match case.start {
            Some(start) => member["server_start"] = json!(start),
            None => {
                member.as_object_mut().unwrap().remove("server_start");
            }
        }
        world.plant_fleet(member.clone());
        world.serve(case.served);
        let out = stop(&world, &env);
        assert_eq!(out.code, 0, "{}: {}", case.name, out.stderr);
        let told = if case.unbound {
            vec![format!(
                "session-unbound={SESSION} harness=claude home={} remedy=orch-runtime register --fleet",
                account.display()
            )]
        } else {
            Vec::new()
        };
        assert_eq!(out.keyed(), told, "{}: {}", case.name, out.stderr);
        let after = &world.fleet()["overseer"];
        if case.healed {
            assert_eq!(after["session_id"], SESSION, "{}", case.name);
            assert_eq!(after["server_start"], json!(case.served), "{}", case.name);
        } else {
            assert_eq!(after, &member, "{}: the record moved", case.name);
        }
    }
}

#[test]
fn a_record_missing_its_start_harness_or_session_is_healed_once_and_an_unwritable_one_reports_record_unhealed()
 {
    // Each case: the field the record lacks and the value the heal writes,
    // the caller's own: its server's start, its harness, its native session
    // and its account directory.
    type Healed = fn(&TurnWorld) -> Value;
    let cases: [(&str, Healed); 4] = [
        ("server_start", |_| json!(TURN_SERVER_START)),
        ("harness", |_| json!("claude")),
        ("session_id", |_| json!(SESSION)),
        ("home", |world| {
            json!(world.root.join("accounts/claude-1").display().to_string())
        }),
    ];
    for (field, healed) in cases {
        let world = TurnWorld::new();
        let (env, account) = claude_on(&world, PANE);
        let mut member = world.controller(PANE, "claude", &account, SESSION);
        member.as_object_mut().unwrap().remove(field);
        world.plant_fleet(member);
        let out = stop(&world, &env);
        assert_eq!(out.code, 0, "{field}: {}", out.stderr);
        assert!(out.keyed().is_empty(), "{field}: {}", out.stderr);
        assert_eq!(world.fleet()["overseer"][field], healed(&world), "{field}");
        let written = fs::read(world.fleet_path()).unwrap();
        let again = stop(&world, &env);
        assert!(again.keyed().is_empty(), "{field}: {}", again.stderr);
        assert_eq!(
            fs::read(world.fleet_path()).unwrap(),
            written,
            "{field}: a healed record is written again"
        );
    }

    let world = TurnWorld::new();
    let (env, account) = claude_on(&world, PANE);
    let mut member = world.controller(PANE, "claude", &account, SESSION);
    member.as_object_mut().unwrap().remove("session_id");
    world.plant_fleet(member.clone());
    let state = world.fleet_path().parent().unwrap().to_path_buf();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o555)).unwrap();
    let out = stop(&world, &env);
    fs::set_permissions(&state, fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(out.code, 0, "{}", out.stderr);
    let unhealed = format!("record-unhealed={} {PANE}", world.server_pid());
    assert_eq!(out.keyed(), [unhealed.as_str()], "{}", out.stderr);
    assert_eq!(world.fleet()["overseer"], member, "the record moved");
}

#[test]
fn a_managed_jarvis_session_registered_as_its_homes_overseer_is_judged_as_jarvis() {
    // The fleet record binds the Jarvis session at the checkout's root and
    // lacks its native session: Jarvis's own reader is asked first all the
    // same, its terminal check reading the session's pane through the
    // stand-in, and the heal shows the binding kept. A record Jarvis's
    // reader cannot read is told and asks no terminal. Jarvis's reader is
    // asked at a turn end or a context reading alone.
    for unreadable in [false, true] {
        let world = TurnWorld::new();
        let (env, account, record) = jarvis_on(&world);
        if unreadable {
            fs::write(&record, "{").unwrap();
        }
        world.plant_fleet(world.controller(PANE, "claude", &account, ""));
        let out = stop(&world, &env);
        assert_eq!(out.code, 0, "unreadable {unreadable}: {}", out.stderr);
        let told = if unreadable {
            vec![format!("jarvis-record-unread={}", record.display())]
        } else {
            Vec::new()
        };
        assert_eq!(out.keyed(), told, "unreadable {unreadable}: {}", out.stderr);
        assert_eq!(
            world.fleet()["overseer"]["session_id"],
            SESSION,
            "unreadable {unreadable}: the binding is not kept"
        );
        let calls = world.tmux_calls();
        let mut answered = terminal_reads();
        answered.push("display-message -p #{pid} #{start_time}".to_owned());
        answered.push("display-message -p #{pid}".to_owned());
        assert!(
            calls.iter().all(|call| answered.contains(call)),
            "unreadable {unreadable}: a read the table does not hold: {calls:?}"
        );
        for read in terminal_reads() {
            assert_eq!(
                calls.contains(&read),
                !unreadable,
                "unreadable {unreadable}: {read}: {calls:?} {}",
                out.stderr
            );
        }
    }

    // A launch naming its record where no session owner is installed beside
    // the mailbox reader names no Jarvis session and tells nothing.
    let world = TurnWorld::new();
    let (mut env, account) = claude_on(&world, PANE);
    let session = world.jarvis_session(PANE, "claude", SESSION, "4", &account);
    let record = world.plant_jarvis(&world.checkout, session);
    env.push(("JARVIS_RECORD".to_owned(), record.display().to_string()));
    env.push(("JARVIS_GENERATION".to_owned(), "4".to_owned()));
    world.plant_fleet(world.controller(PANE, "claude", &account, ""));
    let out = stop(&world, &env);
    assert_eq!(out.code, 0, "no owner: {}", out.stderr);
    assert!(out.keyed().is_empty(), "no owner: {}", out.stderr);
    assert_eq!(world.fleet()["overseer"]["session_id"], SESSION, "no owner");

    // A launch naming a generation its record no longer holds is read and
    // names no Jarvis session; nothing is told.
    let world = TurnWorld::new();
    let (mut env, account, _) = jarvis_on(&world);
    env.retain(|(name, _)| name != "JARVIS_GENERATION");
    env.push(("JARVIS_GENERATION".to_owned(), "3".to_owned()));
    world.plant_fleet(world.controller(PANE, "claude", &account, ""));
    let out = stop(&world, &env);
    assert_eq!(out.code, 0, "stale generation: {}", out.stderr);
    assert!(out.keyed().is_empty(), "stale generation: {}", out.stderr);
    assert_eq!(
        world.fleet()["overseer"]["session_id"],
        SESSION,
        "stale generation"
    );

    // A tool call of the Jarvis session asks Jarvis's reader nothing.
    let world = TurnWorld::new();
    let (env, account, _) = jarvis_on(&world);
    world.plant_fleet(world.controller(PANE, "claude", &account, ""));
    let payload = json!({ "session_id": SESSION, "hook_event_name": "PostToolUse" }).to_string();
    let out = world.turn(&world.checkout, "claude", &["deliver"], &payload, &env);
    assert_eq!(out.code, 0, "tool call: {}", out.stderr);
    assert!(out.keyed().is_empty(), "tool call: {}", out.stderr);
    let calls = world.tmux_calls();
    for read in terminal_reads() {
        assert!(!calls.contains(&read), "tool call: {read}: {calls:?}");
    }
}

#[test]
fn a_session_in_tmux_with_no_pane_takes_its_controllers_pane_and_one_neither_names_is_told_once() {
    // Each world's session runs in tmux with `TMUX_PANE` lost. The file that
    // tells a session once that it is unjudged, under the home's cache.
    let told = |world: &TurnWorld| {
        world
            .home
            .join(".cache/lane-mail/unjudged")
            .join(format!("claude-{SESSION}"))
    };
    let paneless = |world: &TurnWorld| {
        let (mut env, account) = claude_on(world, PANE);
        env.retain(|(name, _)| name != "TMUX_PANE");
        (env, account)
    };

    // The fleet record names this native session on `PANE` and no start: the
    // recovered pane keys the session, and the heal writes its start.
    let world = TurnWorld::new();
    let (env, account) = paneless(&world);
    let mut member = world.controller(PANE, "claude", &account, SESSION);
    member.as_object_mut().unwrap().remove("server_start");
    world.plant_fleet(member);
    let out = stop(&world, &env);
    assert_eq!(out.code, 0, "controller: {}", out.stderr);
    assert_eq!(out.stdout, "", "controller: {}", out.stderr);
    assert!(out.keyed().is_empty(), "controller: {}", out.stderr);
    assert_eq!(
        world.fleet()["overseer"]["server_start"],
        json!(TURN_SERVER_START),
        "controller: the recovered pane keyed nothing"
    );
    assert!(fs::metadata(told(&world)).is_err(), "controller: told");

    // No fleet record; the managed Jarvis session at the checkout runs on
    // `PANE` and the launch's variables are lost too: Jarvis's own reader
    // finds the session by its home and names its pane.
    let world = TurnWorld::new();
    let (env, account) = paneless(&world);
    world.install_jarvis(&world.checkout);
    world.plant_pane(PANE, "jarvis", "@7", "4", false);
    let mut session = world.jarvis_session(PANE, "claude", SESSION, "4", &account);
    session["generation"] = json!(4);
    session["pending"]["generation"] = json!(4);
    world.plant_jarvis(&world.checkout, session);
    let out = stop(&world, &env);
    assert_eq!(out.code, 0, "jarvis: {}", out.stderr);
    assert_eq!(out.stdout, "", "jarvis: {}", out.stderr);
    assert!(out.keyed().is_empty(), "jarvis: {}", out.stderr);
    let calls = world.tmux_calls();
    for read in terminal_reads() {
        assert!(calls.contains(&read), "jarvis: {read}: {calls:?}");
    }
    assert!(fs::metadata(told(&world)).is_err(), "jarvis: told");

    // The record names this native session on `PANE` at another start of
    // its server, and no Jarvis session stands: a subagent's turn end is not
    // told, the session is told once through Claude's visible warning, and
    // its next turn end passes.
    let world = TurnWorld::new();
    let (env, account) = paneless(&world);
    world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
    world.serve(TURN_SERVER_START + 60);
    let subagent = json!({ "session_id": SESSION, "hook_event_name": "SubagentStop" }).to_string();
    let out = world.turn(&world.checkout, "claude", &[], &subagent, &env);
    assert_eq!(out.code, 0, "subagent: {}", out.stderr);
    assert_eq!(out.stdout, "", "subagent: told");
    assert!(
        fs::metadata(told(&world)).is_err(),
        "subagent: recorded told"
    );
    let out = stop(&world, &env);
    assert_eq!(out.code, 0, "neither: {}", out.stderr);
    let notice: Value = serde_json::from_str(&out.stdout).unwrap_or(Value::Null);
    let first = notice["systemMessage"]
        .as_str()
        .and_then(|text| text.lines().next());
    assert_eq!(
        first,
        Some("lane-mail-check: session-unjudged=missing-pane"),
        "neither: {} {}",
        out.stdout,
        out.stderr
    );
    assert!(
        fs::metadata(told(&world)).is_ok(),
        "neither: not recorded told"
    );
    let again = stop(&world, &env);
    assert_eq!(again.code, 0, "neither again: {}", again.stderr);
    assert_eq!(again.stdout, "", "neither again: told twice");
    assert_eq!(
        world.fleet()["overseer"]["server_start"],
        json!(TURN_SERVER_START)
    );

    // An automatic compaction of a session neither names is refused, and
    // records no told file: its next turn end is still told.
    let world = TurnWorld::new();
    let (env, _) = paneless(&world);
    let payload = json!({ "session_id": SESSION, "trigger": "auto" }).to_string();
    let out = world.turn(&world.checkout, "claude", &["compact"], &payload, &env);
    assert_eq!(out.code, 2, "compact: {}", out.stderr);
    assert_eq!(
        out.keyed(),
        ["session-unjudged=missing-pane"],
        "compact: {}",
        out.stderr
    );
    assert!(fs::metadata(told(&world)).is_err(), "compact: told");

    // A Pi session neither names is told as context, and a told file that
    // cannot be written is said under the notice's answer.
    let world = TurnWorld::new();
    let (env, _) = paneless(&world);
    fs::create_dir_all(&world.home).unwrap();
    fs::write(world.home.join(".cache"), "").unwrap();
    let payload = json!({ "session_id": SESSION }).to_string();
    let out = world.turn(&world.checkout, "pi", &[], &payload, &env);
    assert_eq!(out.code, 0, "pi: {}", out.stderr);
    let notice: Value = serde_json::from_str(&out.stdout).unwrap_or(Value::Null);
    let first = notice["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .and_then(|text| text.lines().next());
    assert_eq!(
        first,
        Some("lane-mail-check: session-unjudged=missing-pane"),
        "pi: {} {}",
        out.stdout,
        out.stderr
    );
    let unwritten = format!(
        "session-unjudged-cache={}",
        world
            .home
            .join(format!(".cache/lane-mail/unjudged/pi-{SESSION}"))
            .display()
    );
    assert_eq!(out.keyed(), [unwritten.as_str()], "pi: {}", out.stderr);

    // A Codex session neither names is told at its row through Codex's
    // visible warning, as Claude Code's is.
    let world = TurnWorld::new();
    let mut env = world.on_pane(PANE);
    env.retain(|(name, _)| name != "TMUX_PANE");
    env.push((
        "CODEX_HOME".to_owned(),
        world.root.join("accounts/codex-1").display().to_string(),
    ));
    let payload = json!({ "session_id": SESSION, "hook_event_name": "SessionStart" }).to_string();
    let out = world.turn(
        &world.checkout,
        "codex",
        &["row", "SessionStart"],
        &payload,
        &env,
    );
    assert_eq!(out.code, 0, "codex: {}", out.stderr);
    let notice: Value = serde_json::from_str(&out.stdout).unwrap_or(Value::Null);
    let first = notice["systemMessage"]
        .as_str()
        .and_then(|text| text.lines().next());
    assert_eq!(
        first,
        Some("lane-mail-check: session-unjudged=missing-pane"),
        "codex: {} {}",
        out.stdout,
        out.stderr
    );

    // A Copilot context reading of a session neither names is refused with
    // nothing on stdout and records no told file; a compaction Copilot did
    // not start itself recovers nothing and passes.
    let world = TurnWorld::new();
    let mut env = world.on_pane(PANE);
    env.retain(|(name, _)| name != "TMUX_PANE");
    env.push((
        "COPILOT_HOME".to_owned(),
        world.root.join("accounts/copilot-1").display().to_string(),
    ));
    let reading = json!({ "session_id": SESSION, "cwd": world.checkout,
                          "current_tokens": 199_000, "token_limit": 272_000 });
    let out = world.turn(
        &world.checkout,
        "copilot",
        &["usage"],
        &reading.to_string(),
        &env,
    );
    assert_eq!(out.code, 2, "copilot: {}", out.stderr);
    assert_eq!(out.stdout, "", "copilot: {}", out.stderr);
    assert_eq!(
        out.keyed(),
        ["session-unjudged=missing-pane"],
        "copilot: {}",
        out.stderr
    );
    let cache = world.home.join(".cache/lane-mail/unjudged");
    assert!(fs::metadata(&cache).is_err(), "copilot: told");
    let (env, _) = paneless(&world);
    let payload = json!({ "session_id": SESSION, "trigger": "manual" }).to_string();
    let out = world.turn(&world.checkout, "claude", &["compact"], &payload, &env);
    assert_eq!(out.code, 0, "manual compact: {}", out.stderr);
    assert!(out.keyed().is_empty(), "manual compact: {}", out.stderr);
    assert!(fs::metadata(&cache).is_err(), "manual compact: told");
}
