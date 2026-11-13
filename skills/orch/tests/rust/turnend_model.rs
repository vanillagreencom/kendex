//! Process tests of a Claude session's model switch at `PostModelSwitch`:
//! the check recorded once per launch, the once-only notice of a model that
//! cannot be read, and the controller's recovery marked started before it
//! asks its successor. Every row runs the real `orch-runtime turn-end` in a
//! [`support::TurnWorld`].
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant records and read the answer of the binary they start"
)]

#[path = "support.rs"]
mod support;

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use support::*;

const ITEM: &str = "ken-1";
const PANE: &str = "%5";
const SESSION: &str = "native-1";

fn git(dir: &Path, args: &[&str]) {
    let out = program("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .expect("git");
    assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
}

/// A launched lane under the world's root: its checkout on its item's
/// branch, the launch marker binding it and its mailbox.
fn lane_in(world: &TurnWorld) -> PathBuf {
    let lane = world.root.join("lane");
    fs::create_dir_all(&lane).unwrap();
    for args in [
        &["init", "-q"][..],
        &["config", "gc.auto", "0"],
        &["config", "maintenance.auto", "false"],
        &["checkout", "-q", "-b", ITEM],
        &["commit", "-q", "--allow-empty", "-m", "base"],
    ] {
        git(&lane, args);
    }
    let marks = lane.join(".git/lane-mail");
    fs::create_dir_all(&marks).unwrap();
    fs::write(marks.join(ITEM), format!("{}\n", lane.display())).unwrap();
    fs::create_dir_all(lane.join("tmp/lane-mail").join(ITEM)).unwrap();
    lane
}

/// The lane's fleet entry: launched on `model` on the world's pane `PANE`
/// for the native session `SESSION`.
fn entry(world: &TurnWorld, model: &str) -> Value {
    json!({
        "item": ITEM,
        "model": model,
        "launch": { "pane": PANE, "server": world.server_pid().to_string() },
        "launched_at": "2026-11-12T00:00:00Z",
        "session_id": SESSION,
    })
}

fn fleet_path(lane: &Path) -> PathBuf {
    lane.join("tmp")
        .join(agent_runtime::record::FLEET_FILE_NAME)
}

fn plant_lanes(lane: &Path, lanes: Value) {
    fs::write(fleet_path(lane), json!({ "lanes": lanes }).to_string()).unwrap();
}

fn read(path: &Path) -> Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

/// The `PostModelSwitch` payload of `session` naming `to`.
fn switched(session: &str, to: Option<&str>) -> String {
    let mut payload = json!({ "hook_event_name": "PostModelSwitch", "session_id": session });
    if let Some(to) = to {
        payload["to_model"] = json!(to);
    }
    payload.to_string()
}

/// The first line of the context a switch handed the session, empty where
/// it handed none.
fn handed(out: &TurnOut) -> String {
    if out.stdout.is_empty() {
        return String::new();
    }
    let answer: Value = serde_json::from_str(out.stdout.trim_end()).unwrap();
    assert_eq!(
        answer["hookSpecificOutput"]["hookEventName"], "PostModelSwitch",
        "{}",
        out.stdout
    );
    answer["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .unwrap_or_default()
        .lines()
        .next()
        .unwrap_or_default()
        .to_owned()
}

fn lane_turn(world: &TurnWorld, lane: &Path, harness: &str, payload: &str, pane: &str) -> TurnOut {
    world.turn(lane, harness, &[], payload, &world.on_pane(pane))
}

/// A lane's switch on the pane and session its launch recorded is recorded
/// once for that launch, its log row kept single when the same switch is
/// told again; a switch inside the launch's own family, and one told by a
/// session or a pane the launch does not run, record nothing.
#[test]
fn a_lanes_switch_is_recorded_once_per_launch_and_a_repeat_or_a_moved_launch_records_nothing() {
    let world = TurnWorld::new();
    let lane = lane_in(&world);
    plant_lanes(&lane, json!([entry(&world, "opus")]));
    let payload = switched(SESSION, Some("claude-sonnet-4-5"));
    for told in ["first", "again"] {
        let out = lane_turn(&world, &lane, "claude", &payload, PANE);
        assert_eq!(out.code, 0, "{told}: {}", out.stderr);
        assert_eq!(out.stdout, "", "{told}: handed");
        let fleet = read(&fleet_path(&lane));
        let check = &fleet["lanes"][0]["model_check"];
        assert_eq!(check["outcome"], "switched", "{told}: {fleet}");
        assert_eq!(check["recovery_started"], false, "{told}: {fleet}");
        assert_eq!(check["observed"], "claude-sonnet-4-5", "{told}");
        let rows: Vec<&Value> = fleet["fleet_log"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|row| row["kind"] == "model-switched")
            .collect();
        assert_eq!(rows.len(), 1, "{told}: {fleet}");
    }

    for (case, model, to, session, pane) in [
        ("same family", "opus", "claude-opus-5-5", SESSION, PANE),
        ("another pane", "opus", "claude-sonnet-4-5", SESSION, "%6"),
        (
            "another session",
            "opus",
            "claude-sonnet-4-5",
            "native-2",
            PANE,
        ),
    ] {
        let world = TurnWorld::new();
        let lane = lane_in(&world);
        plant_lanes(&lane, json!([entry(&world, model)]));
        let out = lane_turn(&world, &lane, "claude", &switched(session, Some(to)), pane);
        assert_eq!(out.code, 0, "{case}: {}", out.stderr);
        assert_eq!(out.stdout, "", "{case}: handed");
        let fleet = read(&fleet_path(&lane));
        assert!(
            fleet["lanes"][0]["model_check"].is_null(),
            "{case}: {fleet}"
        );
        assert!(fleet["fleet_log"].is_null(), "{case}: {fleet}");
    }
}

/// A model the launch names none of, cannot resolve or the event does not
/// name, and a switch that cannot be bound to the launch or names a lane
/// the record does not hold, is handed to the session once: the check, or
/// the item's slot for the session, takes it, and the same session's next
/// switch is handed nothing.
#[test]
fn an_unavailable_model_is_handed_over_once_per_session() {
    for (case, lanes, session, to, cause) in [
        (
            "no model",
            Some(""),
            SESSION,
            Some("claude-sonnet-4-5"),
            "launch-missing",
        ),
        (
            "alien model",
            Some("gpt-5"),
            SESSION,
            Some("claude-sonnet-4-5"),
            "launch-unresolved",
        ),
        ("no target", Some("opus"), SESSION, None, "observed-unread"),
        (
            "no session",
            Some("opus"),
            "",
            Some("claude-sonnet-4-5"),
            "launch-unbound",
        ),
        (
            "no lane",
            None,
            SESSION,
            Some("claude-sonnet-4-5"),
            "launch-missing",
        ),
    ] {
        let world = TurnWorld::new();
        let lane = lane_in(&world);
        match lanes {
            Some(model) => plant_lanes(&lane, json!([entry(&world, model)])),
            None => plant_lanes(&lane, json!([])),
        }
        let payload = switched(session, to);
        let out = lane_turn(&world, &lane, "claude", &payload, PANE);
        assert_eq!(out.code, 0, "{case}: {}", out.stderr);
        assert_eq!(
            handed(&out),
            format!("lane-mail-check: model-unavailable={cause}"),
            "{case}: {}",
            out.stderr
        );
        let again = lane_turn(&world, &lane, "claude", &payload, PANE);
        assert_eq!(again.code, 0, "{case} again: {}", again.stderr);
        assert_eq!(handed(&again), "", "{case} again: handed twice");
    }
}

/// The lane's fleet entry once its replacement runs: a switched check whose
/// recovery started under the earlier launch on pane `%4`.
fn replaced(world: &TurnWorld) -> Value {
    let mut replaced = entry(world, "opus");
    let earlier = json!({ "pane": "%4", "server": world.server_pid().to_string() });
    replaced["model_check"] = json!({
        "outcome": "switched",
        "session_id": SESSION,
        "recovery_started": true,
        "launch_identity": { "launch": earlier, "launched_at": "2026-11-11T00:00:00Z" },
    });
    replaced
}

/// A replacement's first Stop on the launch its record now names resets
/// the switched check whose recovery started under the earlier launch, with
/// one log row however often it stops; a Stop from a pane the launch does
/// not run resets nothing.
#[test]
fn a_replacements_first_stop_resets_its_lanes_switched_check_once() {
    for (case, pane, reset) in [("replaced", PANE, true), ("another pane", "%6", false)] {
        let world = TurnWorld::new();
        let lane = lane_in(&world);
        plant_lanes(&lane, json!([replaced(&world)]));
        let payload = json!({ "hook_event_name": "Stop", "session_id": SESSION }).to_string();
        for told in ["first", "again"] {
            let out = lane_turn(&world, &lane, "claude", &payload, pane);
            assert_eq!(out.code, 0, "{case} {told}: {}", out.stderr);
            let fleet = read(&fleet_path(&lane));
            let outcome = &fleet["lanes"][0]["model_check"]["outcome"];
            let rows = fleet["fleet_log"].as_array().map_or(0, |rows| {
                rows.iter()
                    .filter(|row| row["kind"] == "model-recovery-reset")
                    .count()
            });
            let want = if reset { "passed" } else { "switched" };
            assert_eq!(outcome, want, "{case} {told}: {fleet}");
            assert_eq!(rows, usize::from(reset), "{case} {told}: {fleet}");
        }
    }
}

/// A replacement's first Stop whose reset cannot read the fleet record,
/// cannot read the server its pane runs on, or has its write refused tells
/// that cause as a note and passes; the switched check stands as it was.
#[test]
fn a_replacements_reset_that_cannot_read_bind_or_write_tells_its_cause() {
    for (case, cause) in [
        ("record unread", "reset-launch-unread"),
        ("server unread", "reset-launch-unbound"),
        ("write refused", "reset-record-unwritten"),
    ] {
        let world = TurnWorld::new();
        let lane = lane_in(&world);
        let fleet = fleet_path(&lane);
        plant_lanes(&lane, json!([replaced(&world)]));
        let mut env = world.on_pane(PANE);
        match case {
            "record unread" => fs::write(&fleet, "{").unwrap(),
            "server unread" => env.retain(|(name, _)| name != "TMUX"),
            _ => {
                let mut lock = fleet.clone().into_os_string();
                lock.push(".lock");
                fs::create_dir(lock).unwrap();
            }
        }
        let payload = json!({ "hook_event_name": "Stop", "session_id": SESSION }).to_string();
        let out = world.turn(&lane, "claude", &[], &payload, &env);
        assert_eq!(out.code, 0, "{case}: {}", out.stderr);
        let told = format!("model-unavailable={cause}");
        assert!(
            out.keyed().contains(&told.as_str()),
            "{case}: {}",
            out.stderr
        );
        if case != "record unread" {
            let fleet = read(&fleet);
            let check = &fleet["lanes"][0]["model_check"];
            assert_eq!(check["outcome"], "switched", "{case}: {fleet}");
            assert!(fleet["fleet_log"].is_null(), "{case}: {fleet}");
        }
    }
}

/// A controller's acquired switch is marked started before its successor
/// is asked: a successor that cannot be chosen (here, a launch posture the
/// settings cannot read) leaves the check marked, so the next switch is a
/// duplicate rather than a second recovery, and the refusal is handed to
/// the session once.
#[test]
fn a_controllers_switch_marks_its_recovery_started_before_it_asks_its_successor() {
    let world = TurnWorld::new();
    let account = world.root.join("accounts/claude-1");
    let mut env = world.on_pane(PANE);
    env.push((
        "CLAUDE_CONFIG_DIR".to_owned(),
        account.display().to_string(),
    ));
    env.push((
        "AGENT_RUNTIME_LAUNCH_PERMISSION".to_owned(),
        "no-such-posture".to_owned(),
    ));
    let mut member = world.controller(PANE, "claude", &account, SESSION);
    member["model"] = json!("opus");
    world.plant_fleet(member);
    let payload = switched(SESSION, Some("claude-sonnet-4-5"));
    let out = world.turn(&world.checkout, "claude", &[], &payload, &env);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        handed(&out),
        "lane-mail-check: model-unavailable=recovery-unstarted",
        "{}",
        out.stderr
    );
    let fleet = world.fleet();
    let check = &fleet["overseer"]["model_check"];
    assert_eq!(check["outcome"], "switched", "{fleet}");
    assert_eq!(check["recovery_started"], true, "{fleet}");
    let reads = "display-message -p #{pid} #{start_time}";
    for call in world.tmux_calls() {
        assert_eq!(call, reads, "a tmux call past the server read");
    }
    let again = world.turn(&world.checkout, "claude", &[], &payload, &env);
    assert_eq!(again.code, 0, "again: {}", again.stderr);
    assert_eq!(handed(&again), "", "again: handed twice");
}

/// The planted account a lane's credential lives in, as the listing names it.
const ACCOUNT: &str = "/home/me/.aclaude";

/// A launch record naming a native identity file, as a hosted provider
/// records it.
const HOSTED_RECORD: &str = r#"{"identity_file": "/sandbox/identity"}"#;

/// [`ACCOUNT`]'s row of the listing: a measured Claude account whose weekly
/// window, its binding, is `weekly` percent used, read this instant.
fn account_row(weekly: u64) -> Value {
    let now = now_ms() / 1000;
    let iso = |secs: u64| agent_runtime::clock::iso_utc(now + secs);
    json!({
        "alias": "aclaude",
        "harness": "claude",
        "config_dir": ACCOUNT,
        "measured_through": "local",
        "status": "ok",
        "headroom_pct": 100 - weekly,
        "binding_bucket": "weekly",
        "binding_resets_at": iso(60 * 3600),
        "session_5h_pct": 5,
        "weekly_pct": weekly,
        "model_buckets": [],
        "resets": {"session": iso(3600), "weekly": iso(60 * 3600), "model": null, "monthly": null},
        "usage_rate_state": "measured",
        "usage_rate_pct_per_min": 0.005,
        "usage_age_s": 0,
    })
}

/// The line the account mark told, the first keyed line naming the account,
/// its mark or its setting; `None` where it told nothing.
fn account_line(out: &TurnOut) -> Option<String> {
    out.keyed()
        .into_iter()
        .find(|line| {
            ["account=", "headroom=", "seat-reserve=", "setting-range="]
                .iter()
                .any(|key| line.starts_with(key))
        })
        .map(str::to_owned)
}

/// A Stop of the lane's lead naming no transcript, so the context mark
/// takes no reading and the account is judged account-wide.
fn stop() -> String {
    json!({ "hook_event_name": "Stop", "session_id": SESSION }).to_string()
}

/// The verb run from `lane` under the install `hooks`, as
/// [`TurnWorld::turn`] runs it, for an install no harness names.
fn turn_under(world: &TurnWorld, lane: &Path, hooks: &Path, env: &[(String, String)]) -> TurnOut {
    use std::io::Write;
    let mut command = isolated();
    command
        .arg("turn-end")
        .arg("--hook-dir")
        .arg(hooks)
        .current_dir(lane)
        .env("PWD", lane)
        .env("HOME", &world.home)
        .env("XDG_STATE_HOME", world.root.join("state"))
        .env("PATH", tool_path(&[&world.stand_ins()]))
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .envs(env.iter().map(|(name, value)| (name, value)))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = command.spawn().expect("orch-runtime");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stop().as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    TurnOut {
        code: out.status.code().expect("an exit status"),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

/// What a case plants beside the listing.
#[derive(Clone, Copy)]
enum Beside {
    Nothing,
    /// The fleet's controller spends the lane's account: an overseer's seat.
    Seat,
    /// The launch record names a native identity file, as a hosted
    /// provider records it.
    Hosted,
    /// A launch record that is no JSON.
    LaunchUnread,
    /// A launch record whose bytes are no text.
    LaunchNotText,
}

/// The lane's launch record, holding `record`.
fn plant_launch_record(lane: &Path, record: &[u8]) {
    let launch = lane.join(".git/lane-launch");
    fs::create_dir_all(&launch).unwrap();
    fs::write(launch.join(format!("{ITEM}.json")), record).unwrap();
}

/// A lane's account mark at a Stop that left its context mark nothing to
/// hold, judged by this binary's own pick over the planted listing: room
/// tells nothing; the headroom mark and a seat's reserve hold the turn end
/// with the handoff; the owner's word, a directory the inventory does not
/// hold, an account nothing measured, a hosted lane, a Pi reading that named
/// no model and an install naming no harness are told and passed; a
/// headroom setting outside its form holds on the setting.
#[test]
fn a_lanes_account_mark_tells_each_answer_the_judge_gives() {
    let mut unmeasured = account_row(10);
    unmeasured["status"] = json!("no_credentials");
    type Case<'a> = (
        &'a str,
        Value,
        &'a str,
        &'a [(&'a str, &'a str)],
        &'a str,
        Beside,
        i32,
        Option<&'a str>,
    );
    let cases: Vec<Case> = vec![
        (
            "room",
            account_row(10),
            "claude",
            &[],
            ".aclaude",
            Beside::Nothing,
            0,
            None,
        ),
        (
            "walled",
            account_row(98),
            "claude",
            &[],
            ".aclaude",
            Beside::Nothing,
            2,
            Some("headroom=2 bucket=weekly mark=3"),
        ),
        (
            "seat",
            account_row(92),
            "claude",
            &[],
            ".aclaude",
            Beside::Seat,
            2,
            Some("seat-reserve=8 bucket=weekly need="),
        ),
        (
            "the owner's word",
            account_row(10),
            "claude",
            &[("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "aclaude")],
            ".aclaude",
            Beside::Nothing,
            0,
            Some("account=excluded"),
        ),
        (
            "unlisted account",
            account_row(10),
            "claude",
            &[],
            ".other",
            Beside::Nothing,
            0,
            Some("account=unlisted"),
        ),
        (
            "unmeasured",
            unmeasured,
            "claude",
            &[],
            ".aclaude",
            Beside::Nothing,
            0,
            Some("account=unmeasured"),
        ),
        (
            "hosted",
            account_row(98),
            "claude",
            &[],
            ".aclaude",
            Beside::Hosted,
            0,
            Some("account=host-measured"),
        ),
        (
            "launch record unread",
            account_row(98),
            "claude",
            &[],
            ".aclaude",
            Beside::LaunchUnread,
            0,
            Some("account=unmeasured"),
        ),
        (
            "launch record not text",
            account_row(98),
            "claude",
            &[],
            ".aclaude",
            Beside::LaunchNotText,
            0,
            Some("account=unmeasured"),
        ),
        (
            "pi with no model",
            account_row(10),
            "pi",
            &[],
            ".aclaude",
            Beside::Nothing,
            0,
            Some("account=unmeasured"),
        ),
        (
            "unlisted harness",
            account_row(10),
            "",
            &[],
            ".aclaude",
            Beside::Nothing,
            0,
            Some("account=unlisted"),
        ),
        (
            "headroom setting",
            account_row(10),
            "claude",
            &[("ORCH_HANDOFF_HEADROOM_PCT", "101")],
            ".aclaude",
            Beside::Nothing,
            2,
            Some("setting-range=ORCH_HANDOFF_HEADROOM_PCT=101"),
        ),
    ];
    for (case, row, harness, extra, dir, beside, code, want) in cases {
        let world = TurnWorld::new();
        let lane = lane_in(&world);
        let now = now_ms() / 1000;
        let planted = plant_listing(&world.root, &world.account_state(), &[row], now);
        let account = world.home.join(dir);
        match beside {
            Beside::Nothing => {}
            Beside::Seat => fs::write(
                fleet_path(&lane),
                json!({ "overseer": { "account": world.home.join(".aclaude") }, "lanes": [] })
                    .to_string(),
            )
            .unwrap(),
            Beside::Hosted => plant_launch_record(&lane, HOSTED_RECORD.as_bytes()),
            Beside::LaunchUnread => plant_launch_record(&lane, b"{"),
            Beside::LaunchNotText => plant_launch_record(&lane, &[0xff, 0xfe]),
        }
        let mut env = planted.env;
        env.push((
            "CLAUDE_CONFIG_DIR".to_owned(),
            account.display().to_string(),
        ));
        env.extend(
            extra
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned())),
        );
        let out = if harness.is_empty() {
            turn_under(&world, &lane, &world.root.join("install/hooks"), &env)
        } else {
            world.turn(&lane, harness, &[], &stop(), &env)
        };
        assert_eq!(out.code, code, "{case}: {}", out.stderr);
        let told = account_line(&out);
        match want {
            None => assert_eq!(told, None, "{case}: {}", out.stderr),
            Some(want) => assert!(
                told.as_deref().is_some_and(|line| line.starts_with(want)),
                "{case}: {told:?}\n{}",
                out.stderr
            ),
        }
    }
}

/// A row of the listing for `harness`'s own directory under the home,
/// walled at 98 percent of its binding bucket.
fn walled_home_row(harness: &str) -> Value {
    let mut row = account_row(98);
    row["alias"] = json!(format!("{harness}-home"));
    row["harness"] = json!(harness);
    row["config_dir"] = json!(format!("/home/me/.{harness}"));
    if harness == "copilot" {
        row["binding_bucket"] = json!("monthly");
        row["monthly_pct"] = json!(98);
        row["plan"] = json!("individual");
        row["resets"]["monthly"] = row["resets"]["weekly"].clone();
    }
    row
}

/// How a case's session names the account it runs, and what it plants
/// beside its listing.
#[derive(Clone, Copy)]
enum Named {
    /// No home variable: the harness's own directory under `HOME`.
    Home,
    /// `LANES_HOME` names the home the harness's directory is under.
    LanesHome,
    /// `LANES_HOME` set empty, which names no home.
    LanesHomeEmpty,
    /// The harness's own directory under `HOME`, and a launch record
    /// naming a native identity file.
    HomeHosted,
    /// `CLAUDE_CONFIG_DIR` names [`ACCOUNT`]'s directory, and the lane
    /// root's private env file excludes that account.
    PrivateEnv,
    /// `CLAUDE_CONFIG_DIR` names [`ACCOUNT`]'s directory, and the Stop
    /// names a transcript whose session runs the model held here.
    Transcript(&'static str),
    /// No home variable, and the Stop names a Pi transcript whose session
    /// runs the `github-copilot/` model held here; the owner states the
    /// Copilot pool of the Pi root under `HOME`, walled at 98 percent.
    PiTranscript(&'static str),
}

/// The account a lane's mark judges is the one its session runs: with no
/// home variable, the harness's own directory under `LANES_HOME`, or under
/// `HOME` where `LANES_HOME` is unset or empty; a Codex lane's launch record
/// makes no hosted lane; the pick reads no private env file the turn end
/// reads none of; and a session's own model is judged on that model's
/// window, so a walled Opus window holds an Opus session and leaves a
/// Sonnet session its room; a Pi lane's is the Pi root under `HOME` its
/// transcript's provider bills.
#[test]
fn a_lanes_account_mark_judges_the_account_and_model_its_session_names() {
    let walled = "headroom=2 bucket=weekly";
    let mut opus = account_row(10);
    opus["model_buckets"] = json!([{"label": "Opus 5", "pct": 98,
        "resets_at": agent_runtime::clock::iso_utc(now_ms() / 1000 + 4 * 86_400)}]);
    let cases = [
        (
            "claude home",
            "claude",
            walled_home_row("claude"),
            Named::Home,
            2,
            Some(walled),
        ),
        (
            "lanes home",
            "claude",
            walled_home_row("claude"),
            Named::LanesHome,
            2,
            Some(walled),
        ),
        (
            "empty lanes home",
            "claude",
            walled_home_row("claude"),
            Named::LanesHomeEmpty,
            2,
            Some(walled),
        ),
        (
            "codex home",
            "codex",
            walled_home_row("codex"),
            Named::Home,
            2,
            Some(walled),
        ),
        (
            "codex launch record",
            "codex",
            walled_home_row("codex"),
            Named::HomeHosted,
            2,
            Some(walled),
        ),
        (
            "copilot home",
            "copilot",
            walled_home_row("copilot"),
            Named::Home,
            // Copilot's Stop is refused on stdout at status 0.
            0,
            Some("headroom=2 bucket=monthly"),
        ),
        (
            "private env file",
            "claude",
            account_row(10),
            Named::PrivateEnv,
            0,
            None,
        ),
        (
            "own model",
            "claude",
            opus.clone(),
            Named::Transcript("claude-opus-5"),
            2,
            Some("headroom=2 bucket=model"),
        ),
        (
            "another model's window",
            "claude",
            opus,
            Named::Transcript("claude-sonnet-5-5"),
            0,
            None,
        ),
        (
            "pi root",
            "pi",
            account_row(10),
            Named::PiTranscript("gpt-5"),
            2,
            Some("headroom=2 bucket=monthly"),
        ),
    ];
    for (case, harness, row, named, code, want) in cases {
        let world = TurnWorld::new();
        let lane = lane_in(&world);
        let listed = match named {
            Named::LanesHome => world.root.join("lanes"),
            _ => world.root.clone(),
        };
        let planted = plant_listing(&listed, &world.account_state(), &[row], now_ms() / 1000);
        let mut env: Vec<(String, String)> = planted
            .env
            .into_iter()
            .filter(|(name, _)| name != "HOME")
            .collect();
        let mut add = |name: &str, value: String| env.push((name.to_owned(), value));
        let account = world.home.join(".aclaude").display().to_string();
        let mut payload = stop();
        match named {
            Named::Home => {}
            Named::LanesHome => add("LANES_HOME", listed.join("home").display().to_string()),
            Named::LanesHomeEmpty => add("LANES_HOME", String::new()),
            Named::HomeHosted => plant_launch_record(&lane, HOSTED_RECORD.as_bytes()),
            Named::PrivateEnv => {
                add("CLAUDE_CONFIG_DIR", account);
                fs::write(
                    lane.join(".env.local"),
                    "AGENT_RUNTIME_ACCOUNT_EXCLUDE=aclaude\n",
                )
                .unwrap();
            }
            Named::Transcript(model) => {
                add("CLAUDE_CONFIG_DIR", account);
                add("DISABLE_AUTO_COMPACT", "1".to_owned());
                let transcript = world.root.join("transcript.jsonl");
                let usage = json!({"type": "assistant", "message": {"model": model,
                    "usage": {"input_tokens": 1, "cache_read_input_tokens": 992,
                              "cache_creation_input_tokens": 0, "output_tokens": 7}}});
                fs::write(&transcript, format!("{usage}\n")).unwrap();
                payload = json!({ "hook_event_name": "Stop", "session_id": SESSION,
                                  "transcript_path": transcript })
                .to_string();
            }
            Named::PiTranscript(model) => {
                let root = world.home.join(".pi").join("agent");
                fs::create_dir_all(&root).unwrap();
                add(
                    "AGENT_RUNTIME_COPILOT_POOL",
                    format!("{}=98/100", root.display()),
                );
                let transcript = world.root.join("transcript.jsonl");
                let usage = json!({"type": "message", "message": {"role": "assistant",
                    "provider": "github-copilot", "model": model,
                    "usage": {"input": 1, "output": 7, "cacheRead": 992, "cacheWrite": 0}}});
                fs::write(&transcript, format!("{usage}\n")).unwrap();
                payload = json!({ "hook_event_name": "Stop", "session_id": SESSION,
                                  "transcript_path": transcript })
                .to_string();
            }
        }
        let out = world.turn(&lane, harness, &[], &payload, &env);
        assert_eq!(out.code, code, "{case}: {}", out.stderr);
        let told = account_line(&out);
        match want {
            None => assert_eq!(told, None, "{case}: {}", out.stderr),
            Some(want) => assert!(
                told.as_deref().is_some_and(|line| line.starts_with(want)),
                "{case}: {told:?}\n{}",
                out.stderr
            ),
        }
    }
}

/// An account read that outlasts the ceiling, here the provider's listing
/// held past it, is killed with its group and told `account=timeout`, and the
/// turn ends; the held read is the planted provider's, which would end on
/// its own bound past the ceiling.
#[test]
fn an_account_read_past_its_ceiling_is_told_and_passed() {
    let world = TurnWorld::new();
    let lane = lane_in(&world);
    let scripts = lane.join(".agents/skills/orch/scripts");
    fs::create_dir_all(&scripts).unwrap();
    std::os::unix::fs::symlink(
        fixtures().join("lane-host-hold/lane-host"),
        scripts.join("lane-host"),
    )
    .unwrap();
    let fifo = world.root.join("accounts.fifo");
    mkfifo(&fifo);
    let now = now_ms() / 1000;
    let mut env = plant_listing(&world.root, &world.account_state(), &[], now).env;
    for (name, value) in [
        ("ORCH_LANE_HOST", "fleet-vm".to_owned()),
        ("LANE_HOST_HOLD_FIFO", fifo.display().to_string()),
        ("HOLD_BOUND_SECS", "25".to_owned()),
        (
            "CLAUDE_CONFIG_DIR",
            world.home.join(".aclaude").display().to_string(),
        ),
    ] {
        env.push((name.to_owned(), value));
    }
    let out = world.turn(&lane, "claude", &[], &stop(), &env);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        account_line(&out).as_deref(),
        Some("account=timeout"),
        "{}",
        out.stderr
    );
    let held = fs::read_to_string(world.root.join("accounts.fifo.log")).unwrap_or_default();
    assert_eq!(
        held, "accounts\n",
        "the held read is the provider's listing"
    );
}

/// Only a Claude session's switch is judged, the one harness whose model
/// ids the rule reads: the same event under another harness's install
/// records nothing.
#[test]
fn a_model_switch_under_another_harness_install_passes_silently() {
    let world = TurnWorld::new();
    let lane = lane_in(&world);
    plant_lanes(&lane, json!([entry(&world, "opus")]));
    let payload = switched(SESSION, Some("claude-sonnet-4-5"));
    let out = lane_turn(&world, &lane, "codex", &payload, PANE);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.stdout, "", "handed");
    let fleet = read(&fleet_path(&lane));
    assert!(fleet["lanes"][0]["model_check"].is_null(), "{fleet}");
}

/// A lane's Stop under settings that do not load, a mark key out of form
/// in the checkout's settings file, passes with the gap told before any
/// mark: no account is judged.
#[test]
fn settings_that_do_not_load_pass_a_lanes_stop_unanswered() {
    let world = TurnWorld::new();
    let lane = lane_in(&world);
    plant_lanes(&lane, json!([entry(&world, "opus")]));
    fs::write(
        lane.join("kendex.settings.toml"),
        "[env]\nORCH_HANDOFF_CONTEXT_PCT = \"90\n",
    )
    .unwrap();
    let out = lane_turn(&world, &lane, "claude", &stop(), PANE);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        out.keyed().first().copied(),
        Some("handoff-unanswered=settings"),
        "{}",
        out.stderr
    );
    assert_eq!(account_line(&out), None, "{}", out.stderr);
}
