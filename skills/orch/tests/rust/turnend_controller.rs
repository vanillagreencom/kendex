//! Process tests of a controller's own turn end: the overseer's and a
//! managed Jarvis session's context, marks and hand-over, the wake and the
//! overseer's mail. Every row runs the real `orch-runtime turn-end` in a
//! [`support::TurnWorld`].
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant records and read the answer of the binary they start"
)]

#[path = "support.rs"]
mod support;
mod turnend_wake;

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use support::*;

const PANE: &str = "%3";
const SESSION: &str = "native-1";

/// A Claude session on the world's pane `pane` with its account directory
/// named, and that directory.
fn claude_on(world: &TurnWorld, pane: &str) -> (Vec<(String, String)>, PathBuf) {
    let account = world.root.join("accounts/claude-1");
    fs::create_dir_all(&account).unwrap();
    let mut env = world.on_pane(pane);
    env.push((
        "CLAUDE_CONFIG_DIR".to_owned(),
        account.display().to_string(),
    ));
    (env, account)
}

/// A turn end of the session `SESSION` from the fleet's checkout, naming
/// `transcript` where one is given.
fn stop(world: &TurnWorld, env: &[(String, String)], transcript: Option<&Path>) -> TurnOut {
    let mut payload = json!({ "session_id": SESSION });
    if let Some(transcript) = transcript {
        payload["transcript_path"] = json!(transcript.display().to_string());
    }
    world.turn(&world.checkout, "claude", &[], &payload.to_string(), env)
}

/// The overseer mailbox of the world's checkout.
fn overseer_box(world: &TurnWorld) -> PathBuf {
    world.checkout.join("tmp/lane-mail/overseer")
}

/// The overseer's context record, `None` where none was written.
fn box_record(world: &TurnWorld) -> Option<Value> {
    let text = fs::read_to_string(overseer_box(world).join("context.json")).ok()?;
    Some(serde_json::from_str(&text).unwrap())
}

/// The key every controller record carries for the world's pane `pane`.
fn caller_key(world: &TurnWorld, pane: &str) -> String {
    format!("{} {pane}", world.server_pid())
}

/// A Claude Code transcript at `path` holding `lines`.
fn transcript(path: &Path, lines: &[Value]) -> PathBuf {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let text: String = lines.iter().map(|line| format!("{line}\n")).collect();
    fs::write(path, text).unwrap();
    path.to_path_buf()
}

/// A Claude Code usage line as the session writes it, summing to `tokens`.
fn claude_usage(tokens: u64) -> Value {
    json!({"type": "assistant", "message": {"model": "claude-opus-4-5", "usage": {
        "input_tokens": 1, "cache_read_input_tokens": tokens - 8,
        "cache_creation_input_tokens": 0, "output_tokens": 7}}})
}

/// A Claude Code usage line in a form the reader does not take: none of
/// the fields it sums.
fn unread_usage() -> Value {
    json!({"type": "assistant", "message": {"model": "claude-opus-4-5", "usage": {"tokens": 5}}})
}

/// The fleet's overseer records the reading its bound transcript holds, or
/// where it took none, the gap naming why, in the checkout's overseer
/// mailbox under its own key; a transcript under another home is read as no
/// reading of this session's and said so.
#[test]
fn an_overseer_turn_end_records_its_reading_or_its_gap_in_the_overseer_box() {
    type Planted = fn(&TurnWorld, &Path) -> Option<PathBuf>;
    struct Case {
        name: &'static str,
        transcript: Planted,
        tokens: Option<u64>,
        gap: Option<&'static str>,
        unowned: bool,
    }
    let cases = [
        Case {
            name: "a bound reading",
            transcript: |_, account| {
                let path = account.join(format!("projects/p/{SESSION}.jsonl"));
                Some(transcript(&path, &[claude_usage(50_000)]))
            },
            tokens: Some(50_000),
            gap: None,
            unowned: false,
        },
        Case {
            name: "no transcript named",
            transcript: |_, _| None,
            tokens: None,
            gap: Some("transcript-unnamed"),
            unowned: false,
        },
        Case {
            name: "a bound transcript with no usage line",
            transcript: |_, account| {
                let path = account.join(format!("projects/p/{SESSION}.jsonl"));
                Some(transcript(&path, &[json!({"type": "user"})]))
            },
            tokens: None,
            gap: Some("usage-absent"),
            unowned: false,
        },
        Case {
            name: "a transcript under another home",
            transcript: |world, _| {
                let path = world
                    .root
                    .join(format!("accounts/other/projects/p/{SESSION}.jsonl"));
                Some(transcript(&path, &[claude_usage(50_000)]))
            },
            tokens: None,
            gap: Some("home-mismatch"),
            unowned: true,
        },
        Case {
            name: "a bound transcript whose usage line the reader cannot take",
            transcript: |_, account| {
                let path = account.join(format!("projects/p/{SESSION}.jsonl"));
                Some(transcript(&path, &[unread_usage()]))
            },
            tokens: None,
            gap: Some("usage-unread"),
            unowned: false,
        },
    ];
    for case in cases {
        let world = TurnWorld::new();
        let (mut env, account) = claude_on(&world, PANE);
        // Compaction off names the window, so a bound reading below the
        // marks judges as room.
        env.push(("DISABLE_AUTO_COMPACT".to_owned(), "1".to_owned()));
        world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
        let named = (case.transcript)(&world, &account);
        let out = stop(&world, &env, named.as_deref());
        assert_eq!(out.code, 0, "{}: {}", case.name, out.stderr);
        let told = match (&named, case.unowned, case.gap) {
            (Some(path), true, _) => vec![format!("transcript-unowned={}", path.display())],
            (Some(path), false, Some("usage-unread")) => {
                vec![format!("usage-unread={}", path.display())]
            }
            _ => Vec::new(),
        };
        assert_eq!(out.keyed(), told, "{}: {}", case.name, out.stderr);
        let record = box_record(&world).unwrap_or_else(|| panic!("{}: no record", case.name));
        assert_eq!(
            record["tokens"],
            json!(case.tokens),
            "{}: {record}",
            case.name
        );
        assert_eq!(record["gap"], json!(case.gap), "{}: {record}", case.name);
        assert_eq!(
            record["pane_key"],
            json!(caller_key(&world, PANE)),
            "{}: {record}",
            case.name
        );
        assert_eq!(record["session_id"], SESSION, "{}: {record}", case.name);
    }
}

/// A session whose native identity the fleet record names on another pane
/// is the controller the record lost: where the overseer's context record
/// still holds its reading, its turn end records the gap `pane-unrecorded`
/// and says which key the record names now; a record holding another
/// session's reading is left as it stands.
#[test]
fn a_lost_overseer_records_pane_unrecorded_and_meets_no_mark() {
    for own in [true, false] {
        let world = TurnWorld::new();
        let (env, account) = claude_on(&world, PANE);
        world.plant_fleet(world.controller("%9", "claude", &account, SESSION));
        let held = if own {
            caller_key(&world, PANE)
        } else {
            caller_key(&world, "%7")
        };
        let planted = json!({"harness": "claude", "tokens": 390_000, "window": null,
            "session_id": SESSION, "pane_key": held, "gap": null, "at": "2026-11-12T00:00:00Z"});
        fs::create_dir_all(overseer_box(&world)).unwrap();
        fs::write(
            overseer_box(&world).join("context.json"),
            planted.to_string(),
        )
        .unwrap();
        let out = stop(&world, &env, None);
        assert_eq!(out.code, 0, "own {own}: {}", out.stderr);
        let record = box_record(&world).unwrap();
        if !own {
            assert!(out.keyed().is_empty(), "{}", out.stderr);
            assert_eq!(record, planted, "another session's record moved");
            continue;
        }
        let told = format!("pane-unrecorded={}", caller_key(&world, PANE));
        assert_eq!(out.keyed(), [told.as_str()], "{}", out.stderr);
        let named = caller_key(&world, "%9");
        assert!(out.stderr.contains(&format!("\n{named}")), "{}", out.stderr);
        assert_eq!(record["gap"], "pane-unrecorded", "{record}");
        assert_eq!(record["tokens"], Value::Null, "{record}");
        assert_eq!(
            record["pane_key"],
            json!(caller_key(&world, PANE)),
            "{record}"
        );
    }
}

/// A Copilot session on the world's pane `pane` with its account directory
/// named, and that directory.
fn copilot_on(world: &TurnWorld, pane: &str) -> (Vec<(String, String)>, PathBuf) {
    let account = world.root.join("accounts/copilot-1");
    fs::create_dir_all(&account).unwrap();
    let mut env = world.on_pane(pane);
    env.push(("COPILOT_HOME".to_owned(), account.display().to_string()));
    (env, account)
}

/// The route out a refusal of the overseer names, checked where the session
/// reads it: the successor walked for its own pane from the checkout, the
/// transfer, and the handoff record naming this session by its native id
/// and its key. `mark` is the mark the walk is told, where one sent it.
fn assert_succession(world: &TurnWorld, text: &str, mark: Option<&str>) {
    let mark = mark
        .map(|kind| format!(" --mark {kind}"))
        .unwrap_or_default();
    let walk = format!(
        " successor --fleet --cwd {} --predecessor %3{mark}\n",
        world.checkout.display()
    );
    assert!(text.contains(&walk), "no successor walk {walk:?}: {text}");
    assert!(
        text.contains(" op --fleet --effect-exit --request [REQUEST FILE]\n"),
        "{text}"
    );
    let record = text
        .lines()
        .find_map(|line| line.split_once(" op --fleet --request-json '"))
        .map(|(_, word)| word.trim_end_matches('\''))
        .unwrap_or_else(|| panic!("no handoff record: {text}"));
    let record: Value = serde_json::from_str(record).unwrap();
    assert_eq!(record["op"], "record-overseer-ledger", "{record}");
    assert_eq!(record["session_id"], SESSION, "{record}");
    assert_eq!(
        record["pane_key"],
        json!(caller_key(world, PANE)),
        "{record}"
    );
}

/// The overseer past a mark is held at its turn end and handed the runtime
/// succession for that mark, its handoff record naming this session alone:
/// its context mark whatever the succession setting, at the token count the
/// setting names and told that count, an account mark only
/// while succession is on, and a Copilot compaction flagged for this
/// session whatever a reading says.
#[test]
fn an_overseer_past_a_mark_is_handed_the_runtime_succession() {
    struct Case {
        name: &'static str,
        tokens: u64,
        settings: &'static [(&'static str, &'static str)],
        held: Option<&'static str>,
    }
    const HEADROOM: (&str, &str) = ("AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT", "95");
    const OFF: (&str, &str) = ("AGENT_RUNTIME_CONTROLLER_SUCCESSION", "off");
    const CAP: (&str, &str) = ("ORCH_HANDOFF_CONTEXT_TOKENS", "123457");
    let cases = [
        Case {
            name: "the context mark",
            tokens: 650_000,
            settings: &[],
            held: Some("context=650000"),
        },
        Case {
            name: "the context mark at the setting's count",
            tokens: 150_000,
            settings: &[CAP],
            held: Some("context=150000"),
        },
        Case {
            name: "the context mark, succession off",
            tokens: 650_000,
            settings: &[OFF],
            held: Some("context=650000"),
        },
        Case {
            name: "the headroom mark",
            tokens: 50_000,
            settings: &[HEADROOM],
            held: Some("headroom=90"),
        },
        Case {
            name: "the headroom mark, succession off",
            tokens: 50_000,
            settings: &[HEADROOM, OFF],
            held: None,
        },
        Case {
            name: "below every mark",
            tokens: 50_000,
            settings: &[],
            held: None,
        },
    ];
    for case in cases {
        let name = case.name;
        let world = TurnWorld::new();
        let (mut env, account) = claude_on(&world, PANE);
        env.push(("DISABLE_AUTO_COMPACT".to_owned(), "1".to_owned()));
        for (key, value) in case.settings {
            env.push(((*key).to_owned(), (*value).to_owned()));
        }
        world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
        let path = account.join(format!("projects/p/{SESSION}.jsonl"));
        let named = transcript(&path, &[claude_usage(case.tokens)]);
        let out = stop(&world, &env, Some(&named));
        let Some(held) = case.held else {
            assert_eq!(out.code, 0, "{name}: {}", out.stderr);
            assert!(out.keyed().is_empty(), "{name}: {}", out.stderr);
            continue;
        };
        assert_eq!(out.code, 2, "{name}: {}", out.stderr);
        assert_eq!(out.keyed(), [held], "{name}: {}", out.stderr);
        if case.settings.contains(&CAP) {
            assert!(
                out.stderr.contains("123457 tokens used"),
                "{name}: {}",
                out.stderr
            );
        }
        let kind = held.split('=').next();
        assert_succession(&world, &out.stderr, kind);
    }
    let world = TurnWorld::new();
    let (env, account) = copilot_on(&world, PANE);
    world.plant_fleet(world.controller(PANE, "copilot", &account, SESSION));
    fs::create_dir_all(overseer_box(&world)).unwrap();
    fs::write(
        overseer_box(&world).join("compaction.json"),
        json!({ "session_id": SESSION }).to_string(),
    )
    .unwrap();
    let payload = json!({ "session_id": SESSION }).to_string();
    let out = world.turn(&world.checkout, "copilot", &[], &payload, &env);
    assert_eq!(out.code, 0, "{}", out.stderr);
    let answer: Value = serde_json::from_str(&out.stdout).unwrap();
    assert_eq!(answer["decision"], "block", "{}", out.stdout);
    let reason = answer["reason"].as_str().unwrap();
    assert!(
        reason.starts_with("lane-mail-check: compacted=auto\n"),
        "{reason}"
    );
    assert_succession(&world, reason, None);
}

/// An overseer whose account nothing measures is told its marks are
/// unmeasured, with the judge's own answer naming the missing figure, and
/// its turn end passes: a reading nothing took is never read as room, and
/// an overseer whose marks cannot be measured must still end a turn.
#[test]
fn an_overseer_whose_account_is_unmeasured_is_told_and_passed() {
    let world = TurnWorld::new();
    let (mut env, account) = claude_on(&world, PANE);
    env.push(("DISABLE_AUTO_COMPACT".to_owned(), "1".to_owned()));
    world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
    world.unmeasure_overseer("claude");
    let path = account.join(format!("projects/p/{SESSION}.jsonl"));
    let named = transcript(&path, &[claude_usage(50_000)]);
    let out = stop(&world, &env, Some(&named));
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.keyed(), ["marks=unmeasured"], "{}", out.stderr);
    assert!(out.stderr.contains("headroom-none"), "{}", out.stderr);
    assert_eq!(box_record(&world).unwrap()["tokens"], 50_000);
}

/// An overseer whose marks judge refuses, here on a succession setting it
/// does not know, is told the judge's refusal and passed: a session told to
/// run a judge that cannot answer could never end a turn.
#[test]
fn an_overseer_whose_marks_cannot_be_judged_is_told_and_passed() {
    let world = TurnWorld::new();
    let (mut env, account) = claude_on(&world, PANE);
    env.push(("DISABLE_AUTO_COMPACT".to_owned(), "1".to_owned()));
    env.push((
        "AGENT_RUNTIME_CONTROLLER_SUCCESSION".to_owned(),
        "maybe".to_owned(),
    ));
    world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
    let path = account.join(format!("projects/p/{SESSION}.jsonl"));
    let named = transcript(&path, &[claude_usage(50_000)]);
    let out = stop(&world, &env, Some(&named));
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.keyed(), ["marks=unjudged"], "{}", out.stderr);
    assert!(
        out.stderr.contains("AGENT_RUNTIME_CONTROLLER_SUCCESSION"),
        "{}",
        out.stderr
    );
}

/// An overseer whose box cannot take its gap record is told so under its
/// own key, naming the record, and its turn end goes on: no reading stands
/// behind the gap.
#[test]
fn an_overseer_whose_gap_record_cannot_be_written_is_told() {
    let world = TurnWorld::new();
    let (mut env, account) = claude_on(&world, PANE);
    env.push(("DISABLE_AUTO_COMPACT".to_owned(), "1".to_owned()));
    world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
    // A plain file where the overseer box stands: nothing can be made in it.
    let mailbox = overseer_box(&world);
    fs::create_dir_all(mailbox.parent().unwrap()).unwrap();
    fs::write(&mailbox, "").unwrap();
    let elsewhere = world
        .root
        .join(format!("accounts/other/projects/p/{SESSION}.jsonl"));
    let named = transcript(&elsewhere, &[claude_usage(50_000)]);
    let out = stop(&world, &env, Some(&named));
    assert_eq!(out.code, 0, "{}", out.stderr);
    let unowned = format!("transcript-unowned={}", named.display());
    let unrecorded = format!(
        "context-gap-unrecorded={}",
        mailbox.join("context.json").display()
    );
    assert_eq!(
        out.keyed(),
        [unowned.as_str(), unrecorded.as_str()],
        "{}",
        out.stderr
    );
}

/// The keyed lines a call handed the model as its context, none where it
/// handed nothing.
fn handed(out: &TurnOut) -> Vec<String> {
    if out.stdout.is_empty() {
        return Vec::new();
    }
    let answer: Value = serde_json::from_str(&out.stdout).unwrap();
    let text = answer["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .or_else(|| answer["additionalContext"].as_str())
        .unwrap_or_else(|| panic!("no context: {}", out.stdout));
    text.lines()
        .filter_map(|line| line.strip_prefix("lane-mail-check: "))
        .map(str::to_owned)
        .collect()
}

/// The overseer's finished tool calls tell a gap in its reading once per
/// session and first line, and again only once a call with nothing to say
/// has cleared it; a reached context mark is told at every call, and
/// nothing is told while the overseer's own handoff record stands. A call
/// before the overseer mailbox stands is told nothing.
#[test]
fn the_overseer_tool_call_tells_a_gap_once_per_session_and_line() {
    let world = TurnWorld::new();
    let (mut env, account) = claude_on(&world, PANE);
    env.push(("DISABLE_AUTO_COMPACT".to_owned(), "1".to_owned()));
    world.plant_fleet(world.controller(PANE, "claude", &account, SESSION));
    let told = overseer_box(&world).join("context-told");
    let elsewhere = world
        .root
        .join(format!("accounts/other/projects/p/{SESSION}.jsonl"));
    let elsewhere = transcript(&elsewhere, &[claude_usage(50_000)]);
    let gap = format!("transcript-unowned={}", elsewhere.display());
    let gap_told = format!("{SESSION}\tlane-mail-check: {gap}\n");
    let bound = account.join(format!("projects/p/{SESSION}.jsonl"));
    let call = |tokens: Option<u64>| {
        let path = match tokens {
            Some(tokens) => transcript(&bound, &[claude_usage(tokens)]),
            None => elsewhere.clone(),
        };
        let payload =
            json!({ "session_id": SESSION, "transcript_path": path.display().to_string() });
        let out = world.turn(
            &world.checkout,
            "claude",
            &["deliver"],
            &payload.to_string(),
            &env,
        );
        assert_eq!(out.code, 0, "{}", out.stderr);
        out
    };
    // Before any turn end has made the overseer mailbox, a call is judged
    // nowhere: nothing said, the mailbox not made.
    let out = call(None);
    assert_eq!((out.stdout.as_str(), out.stderr.as_str()), ("", ""));
    assert!(
        fs::symlink_metadata(overseer_box(&world)).is_err(),
        "the overseer mailbox was made"
    );
    fs::create_dir_all(overseer_box(&world)).unwrap();
    let reached = "context=650000".to_owned();
    let cached = Some(gap_told.as_str());
    type Step<'a> = (&'a str, Option<u64>, Vec<String>, Option<&'a str>);
    let steps: [Step; 6] = [
        ("a gap first met", None, vec![gap.clone()], cached),
        ("the same gap again", None, Vec::new(), cached),
        ("a call with nothing to say", Some(50_000), Vec::new(), None),
        ("the gap back", None, vec![gap.clone()], cached),
        (
            "a reached mark",
            Some(650_000),
            vec![reached.clone()],
            cached,
        ),
        ("a reached mark again", Some(650_000), vec![reached], cached),
    ];
    for (name, tokens, want, cache) in steps {
        let out = call(tokens);
        assert_eq!(handed(&out), want, "{name}: {}", out.stderr);
        let standing = fs::read_to_string(&told).ok();
        assert_eq!(standing.as_deref(), cache, "{name}: {}", out.stderr);
        if want.is_empty() && tokens.is_none() {
            assert_eq!(out.keyed(), [gap.as_str()], "{name}: said on stderr");
        }
    }
    // The overseer's handoff record stands in the fleet's own state file,
    // naming this session.
    let mut fleet = world.fleet();
    fleet["handoff"] = json!({ "session_id": SESSION, "pane_key": caller_key(&world, PANE) });
    fs::write(world.fleet_path(), fleet.to_string()).unwrap();
    let out = call(Some(650_000));
    assert_eq!(handed(&out), Vec::<String>::new(), "{}", out.stderr);
    assert!(out.keyed().is_empty(), "{}", out.stderr);
}

/// A Copilot fleet controller's session start on a home that loads no
/// context reader is told so as the start's context, naming what the
/// status line fallback lacks; a home whose reader loads, and a session
/// the fleet record does not bind, are told nothing.
#[test]
fn a_copilot_overseers_start_with_no_context_reader_is_told_so() {
    struct Case {
        name: &'static str,
        flag: Option<bool>,
        extension: bool,
        bound: bool,
        cause: Option<&'static str>,
    }
    let cases = [
        Case {
            name: "no reader",
            flag: None,
            extension: false,
            bound: true,
            cause: Some("settings-missing"),
        },
        Case {
            name: "the reader loaded",
            flag: Some(true),
            extension: true,
            bound: true,
            cause: None,
        },
        Case {
            name: "the reader switched off",
            flag: Some(false),
            extension: true,
            bound: true,
            cause: Some("no-status-line"),
        },
        Case {
            name: "no controller",
            flag: None,
            extension: false,
            bound: false,
            cause: None,
        },
    ];
    for case in cases {
        let name = case.name;
        let world = TurnWorld::new();
        let (env, account) = copilot_on(&world, PANE);
        if case.bound {
            world.plant_fleet(world.controller(PANE, "copilot", &account, SESSION));
        }
        if let Some(on) = case.flag {
            let settings = json!({ "enabledFeatureFlags": { "EXTENSIONS": on } });
            fs::write(account.join("settings.json"), settings.to_string()).unwrap();
        }
        if case.extension {
            let extension = account.join("extensions/kendex-lane-context/extension.mjs");
            fs::create_dir_all(extension.parent().unwrap()).unwrap();
            fs::write(&extension, "export {};\n").unwrap();
        }
        let payload = json!({ "session_id": SESSION }).to_string();
        let out = world.turn(&world.checkout, "copilot", &["start"], &payload, &env);
        assert_eq!(out.code, 0, "{name}: {}", out.stderr);
        let Some(cause) = case.cause else {
            assert_eq!(out.stdout, "", "{name}: {}", out.stderr);
            assert!(out.keyed().is_empty(), "{name}: {}", out.stderr);
            continue;
        };
        let keyed = format!(
            "context-reader=missing home={} fix=orch-runtime register --fleet then start a new session",
            account.display()
        );
        assert_eq!(handed(&out), vec![keyed.clone()], "{name}: {}", out.stdout);
        let answer: Value = serde_json::from_str(&out.stdout).unwrap();
        let text = answer["additionalContext"].as_str().unwrap();
        assert!(text.ends_with(&format!("\n{cause}")), "{name}: {text}");
        assert_eq!(out.keyed(), [keyed.as_str()], "{name}: {}", out.stderr);
    }
}

/// A managed Jarvis session of Claude on the world's pane `PANE` whose home
/// is the fleet's checkout: the fleet record binds it as the home's
/// controller and names the seat its start named, `jarvis` where `seat`
/// says so. The session's environment and its account directory.
fn jarvis_on(world: &TurnWorld, seat: bool) -> (Vec<(String, String)>, PathBuf) {
    let (env, account) = claude_on(world, PANE);
    let mut member = world.controller(PANE, "claude", &account, SESSION);
    if seat {
        member["seat"] = json!("jarvis");
    }
    world.plant_fleet(member);
    (env, account)
}

/// A managed Jarvis session past its context mark is held and handed
/// Jarvis's own succession, never the repository overseer's, naming each
/// attached agent still out for it to let finish; below the mark it passes,
/// recording its reading in the overseer mailbox under its key; a
/// transcript under another account home is said and passed. The same
/// controller whose record names no seat is the overseer, never told
/// Jarvis's succession.
#[test]
fn a_jarvis_session_past_its_context_mark_is_handed_its_own_succession() {
    struct Case {
        name: &'static str,
        tokens: u64,
        home: &'static str,
        seat: bool,
        refused: bool,
    }
    let cases = [
        Case {
            name: "past the mark",
            tokens: 650_000,
            home: "claude-1",
            seat: true,
            refused: true,
        },
        Case {
            name: "below the mark",
            tokens: 50_000,
            home: "claude-1",
            seat: true,
            refused: false,
        },
        Case {
            name: "under another account home",
            tokens: 650_000,
            home: "other",
            seat: true,
            refused: false,
        },
        Case {
            name: "past the mark, no seat named",
            tokens: 650_000,
            home: "claude-1",
            seat: false,
            refused: false,
        },
    ];
    let succeed = |world: &TurnWorld| {
        format!(
            "/.agents/skills/jarvis/scripts/jarvis-session succeed --home {}",
            world.checkout.display()
        )
    };
    for case in cases {
        let world = TurnWorld::new();
        let (env, _) = jarvis_on(&world, case.seat);
        let path = world
            .root
            .join("accounts")
            .join(case.home)
            .join(format!("projects/p/{SESSION}.jsonl"));
        let named = transcript(&path, &[claude_usage(case.tokens)]);
        let out = stop(&world, &env, Some(&named));
        let name = case.name;
        if !case.seat {
            assert!(
                !out.stderr.contains("jarvis-session"),
                "{name}: the overseer told Jarvis's succession: {}",
                out.stderr
            );
            continue;
        }
        if case.refused {
            assert_eq!(out.code, 2, "{name}: {}", out.stderr);
            let keyed = format!("context={}", case.tokens);
            assert_eq!(out.keyed(), [keyed.as_str()], "{name}: {}", out.stderr);
            assert!(
                out.stderr.contains(&succeed(&world)),
                "{name}: {}",
                out.stderr
            );
            assert!(
                !out.stderr.contains("successor --fleet"),
                "{name}: {}",
                out.stderr
            );
        } else {
            assert_eq!(out.code, 0, "{name}: {}", out.stderr);
            // Below the token cap a Claude reading with compaction on names
            // no window, so the percentage mark is said unmeasured.
            let told = if case.home == "other" {
                vec![format!("transcript-unowned={}", named.display())]
            } else {
                vec!["window-unread=claude-opus-4-5".to_owned()]
            };
            assert_eq!(out.keyed(), told, "{name}: {}", out.stderr);
        }
        if case.home != "other" {
            let record = box_record(&world).unwrap_or_else(|| panic!("{name}: no record"));
            assert_eq!(record["tokens"], json!(case.tokens), "{name}: {record}");
            assert_eq!(
                record["pane_key"],
                json!(caller_key(&world, PANE)),
                "{name}"
            );
        }
    }
    // An attached agent still out is named, as a lane's and the overseer's
    // are, so the session lets it finish before its succession.
    let world = TurnWorld::new();
    let (env, account) = jarvis_on(&world, true);
    let path = account.join(format!("projects/p/{SESSION}.jsonl"));
    let named = transcript(&path, &[claude_usage(650_000)]);
    let payload = json!({ "session_id": SESSION, "transcript_path": named.display().to_string(),
        "background_tasks": [{"type": "subagent", "id": "a1", "status": "running"}] });
    let out = world.turn(&world.checkout, "claude", &[], &payload.to_string(), &env);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert!(
        out.stderr
            .contains("lane-mail-check: attached-agent=a1 status=running output=unknown"),
        "{}",
        out.stderr
    );
}

/// A managed Jarvis session whose mark cannot be judged, on a setting out
/// of its form or a usage line the reader cannot take, is told the gap and
/// passed, past the mark or not: succeeding the session would not repair
/// the input.
#[test]
fn a_jarvis_session_whose_mark_cannot_be_judged_is_told_and_passed() {
    for setting in [true, false] {
        let world = TurnWorld::new();
        let (mut env, account) = jarvis_on(&world, true);
        if setting {
            env.push(("ORCH_HANDOFF_CONTEXT_PCT".to_owned(), "most".to_owned()));
        }
        let path = account.join(format!("projects/p/{SESSION}.jsonl"));
        let line = if setting {
            claude_usage(650_000)
        } else {
            unread_usage()
        };
        let named = transcript(&path, &[line]);
        let out = stop(&world, &env, Some(&named));
        assert_eq!(out.code, 0, "setting {setting}: {}", out.stderr);
        let keyed = out.keyed();
        if setting {
            assert_eq!(
                keyed,
                ["setting-range=ORCH_HANDOFF_CONTEXT_PCT=most"],
                "{}",
                out.stderr
            );
        } else {
            let unread = format!("usage-unread={}", named.display());
            assert_eq!(keyed, [unread.as_str()], "{}", out.stderr);
        }
        assert!(
            out.stderr.contains("succession mark is unjudged"),
            "setting {setting}: {}",
            out.stderr
        );
    }
}

/// A Claude Haiku usage line summing to `tokens`.
fn haiku_usage(tokens: u64) -> Value {
    json!({"type": "assistant", "message": {"model": "claude-haiku-5-5", "usage": {
        "input_tokens": 1, "cache_read_input_tokens": tokens - 8,
        "cache_creation_input_tokens": 0, "output_tokens": 7}}})
}

/// The bound overseer's attached launch is judged as a lane's is, on the
/// reading its turn end takes: held at the context mark with the runtime
/// succession, and at the mark less the reserve while an attached agent is
/// out; where the roster cannot be read it is held with no succession,
/// which refuses below the plain mark. Its own standing handoff, and a
/// session the fleet record does not bind, pass.
#[test]
fn an_overseer_attached_launch_is_held_at_its_marks() {
    struct Case {
        name: &'static str,
        usage: Value,
        tasks: Value,
        home: &'static str,
        bound: bool,
        own_handoff: bool,
        held: Option<&'static str>,
    }
    let running = json!([{"type": "subagent", "id": "a1", "status": "running"}]);
    let cases = [
        Case {
            name: "the roster unread",
            usage: haiku_usage(30_000),
            tasks: json!("none"),
            home: "claude-1",
            bound: true,
            own_handoff: false,
            held: Some("agent-unobserved=Agent tokens=30000 reserve=150000"),
        },
        Case {
            name: "an attached agent out",
            usage: haiku_usage(30_000),
            tasks: running.clone(),
            home: "claude-1",
            bound: true,
            own_handoff: false,
            held: Some("agent-reserve=Agent tokens=30000 reserve=150000"),
        },
        Case {
            name: "no attached agent out",
            usage: haiku_usage(30_000),
            tasks: json!([]),
            home: "claude-1",
            bound: true,
            own_handoff: false,
            held: None,
        },
        Case {
            name: "past the mark",
            usage: claude_usage(650_000),
            tasks: json!([]),
            home: "claude-1",
            bound: true,
            own_handoff: false,
            held: Some("agent-launch=Agent tokens=650000"),
        },
        Case {
            name: "a transcript under another home",
            usage: claude_usage(650_000),
            tasks: json!([]),
            home: "other",
            bound: true,
            own_handoff: false,
            held: Some("agent-input=home-mismatch"),
        },
        Case {
            name: "past the mark, its own handoff standing",
            usage: claude_usage(650_000),
            tasks: running.clone(),
            home: "claude-1",
            bound: true,
            own_handoff: true,
            held: None,
        },
        Case {
            name: "a session the fleet record does not bind",
            usage: claude_usage(650_000),
            tasks: running,
            home: "claude-1",
            bound: false,
            own_handoff: false,
            held: None,
        },
    ];
    for case in cases {
        let name = case.name;
        let world = TurnWorld::new();
        let (mut env, account) = claude_on(&world, PANE);
        env.push(("DISABLE_AUTO_COMPACT".to_owned(), "1".to_owned()));
        let (pane, session) = if case.bound {
            (PANE, SESSION)
        } else {
            ("%9", "native-other")
        };
        world.plant_fleet(world.controller(pane, "claude", &account, session));
        if case.own_handoff {
            let mut fleet = world.fleet();
            fleet["handoff"] =
                json!({ "session_id": SESSION, "pane_key": caller_key(&world, PANE) });
            fs::write(world.fleet_path(), fleet.to_string()).unwrap();
        }
        let path = world
            .root
            .join("accounts")
            .join(case.home)
            .join(format!("projects/p/{SESSION}.jsonl"));
        let named = transcript(&path, &[case.usage]);
        let payload = json!({ "session_id": SESSION, "transcript_path": named.display().to_string(),
            "tool_name": "Agent", "background_tasks": case.tasks });
        let out = world.turn(
            &world.checkout,
            "claude",
            &["halt"],
            &payload.to_string(),
            &env,
        );
        let Some(held) = case.held else {
            assert_eq!(out.code, 0, "{name}: {}", out.stderr);
            assert!(out.keyed().is_empty(), "{name}: {}", out.stderr);
            continue;
        };
        assert_eq!(out.code, 2, "{name}: {}", out.stderr);
        assert!(out.keyed().contains(&held), "{name}: {}", out.stderr);
        // A wait clears the reserve's hold, so neither names a succession.
        let waits = ["agent-unobserved=", "agent-reserve="];
        if !waits.iter().any(|key| held.starts_with(key)) {
            assert_succession(&world, &out.stderr, None);
        } else {
            assert!(
                !out.stderr.contains(" successor --fleet "),
                "{name}: {}",
                out.stderr
            );
        }
        if case.home == "claude-1" {
            let record = box_record(&world).unwrap_or_else(|| panic!("{name}: no record"));
            assert_eq!(
                record["pane_key"],
                json!(caller_key(&world, PANE)),
                "{name}"
            );
        }
    }
}

/// A session the fleet record binds, in a directory that is no repository,
/// is no controller: `role::read` names it `Kind::None`, and past the
/// context mark its turn end meets nothing, tells nothing and passes. Its
/// pane is the one the record names for its native session, read with
/// `$TMUX` set and no `TMUX_PANE`.
#[test]
fn a_bound_session_outside_a_repository_meets_nothing_past_the_mark() {
    let world = TurnWorld::new();
    let (env, account) = claude_on(&world, PANE);
    let env: Vec<(String, String)> = env
        .into_iter()
        .filter(|(name, _)| name != "TMUX_PANE")
        .collect();
    let dir = world.root.join("assistant");
    let fleet = dir.join("tmp").join(agent_runtime::record::FLEET_FILE_NAME);
    fs::create_dir_all(fleet.parent().unwrap()).unwrap();
    let member = world.controller(PANE, "claude", &account, SESSION);
    fs::write(&fleet, json!({ "controller": member }).to_string()).unwrap();
    let path = account.join(format!("projects/p/{SESSION}.jsonl"));
    let named = transcript(&path, &[claude_usage(650_000)]);
    let payload = json!({ "session_id": SESSION, "transcript_path": named.display().to_string() });
    let out = world.turn(&dir, "claude", &[], &payload.to_string(), &env);
    assert_eq!(
        (out.code, out.stdout.as_str(), out.stderr.as_str()),
        (0, "", ""),
        "{}",
        out.stderr
    );
}
