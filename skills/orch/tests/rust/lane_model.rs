//! A lane's model recovery through the `orch-runtime` executable: the claim
//! on the fleet record, the refusals told before anything stops, and the
//! detached job that retires the predecessor and launches its replacement
//! on the record's own model. Each row makes its own private tmux server
//! and stub harness; a row whose job may start plants the runtime's entry
//! it runs, and a row that must start none plants no entry, so a job a
//! regression starts there ends at its first command.
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests hold owned children and a private tmux server and wait on real time for them"
)]

#[path = "support.rs"]
mod support;

use std::ffi::OsString;
use std::path::Path;
use std::time::{Duration, Instant};

use agent_runtime::journal::Env;
use agent_runtime::record::Locking;
use agent_runtime::settings::Roots;
use orch_runtime::effects::lane_model;
use orch_runtime::ops::lane_model::RecoverLaneModel;
use orch_runtime::settings;
use serde_json::{Value, json};
use support::*;

const ITEM: &str = "KEN-R";

/// The settings a row's request runs under, over the runner's own.
type Settings = &'static [(&'static str, &'static str)];

/// The runtime's entry a recovery's job runs, installed where the
/// checkout at `root` names it.
fn install_entry(root: &Path) {
    let scripts = root.join(".agents/skills/orch/scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    write_executable(
        &scripts.join("orch-runtime"),
        format!(
            "#!/bin/bash\nexec '{}' --no-private-env \"$@\"\n",
            binary().display()
        ),
    );
}

fn identity(lane: &Value) -> Value {
    json!({"launch": lane["launch"], "launched_at": lane["launched_at"]})
}

fn recovery(session: &str, launch_identity: &Value) -> Value {
    json!({
        "op": "recover-lane-model",
        "item": ITEM,
        "session": session,
        "launch_identity": launch_identity,
    })
}

/// The lane's switch as the turn end records it: this session's check bound
/// to the lane's launch, and its row in the fleet log after `log`.
fn switched(fleet: &mut Value, started: bool, log: Vec<Value>) {
    let bound = identity(&fleet["lanes"][0]);
    fleet["lanes"][0]["model_check"] = json!({
        "outcome": "switched", "session_id": "current", "launch_identity": bound,
        "recovery_started": started,
    });
    let mut rows = log;
    rows.push(json!({
        "kind": "model-switched", "item": ITEM, "session_id": "current",
        "launch_identity": bound,
    }));
    fleet["fleet_log"] = json!(rows);
}

/// A running lane no launch of this row made: a gone predecessor, its
/// checkout `root`.
fn planted_lane(runner: &Runner, root: &Path) -> Value {
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([{
        "item": ITEM,
        "harness": "claude",
        "status": "running",
        "mail_root": root.display().to_string(),
        "model": "claude-fable-5-1",
        "effort": "high",
        "class": CLASS,
        "class_reason": CLASS_REASON,
        "launched_at": "2026-11-12T10:00:00Z",
        "launch": {"pid": GONE_PID, "start": "ticks:1"},
    }]);
    fleet
}

fn refusal(out: &std::process::Output) -> (String, Vec<(String, String)>) {
    let answer = reply(out);
    assert_eq!(answer["ok"], false, "{answer}");
    let fields = answer["refusal"]["fields"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pair| {
            (
                pair[0].as_str().unwrap().to_owned(),
                pair[1].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    (
        answer["refusal"]["key"].as_str().unwrap().to_owned(),
        fields,
    )
}

fn field(fields: &[(String, String)], name: &str) -> String {
    fields
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.clone())
        .unwrap_or_default()
}

/// A switched lane's recovery claims the switch once, and its job closes
/// the predecessor on the `model-switch` ground, interrupting its turn,
/// then launches the replacement on the record's own model through the
/// real `launch-lane`, marking the switch's row `replaced`. A second
/// request for the same switch is refused while or after the job runs.
#[test]
fn a_switched_lanes_recovery_is_claimed_once_and_relaunched_on_its_recorded_model() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(2);
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    install_entry(&work);
    let report = effect_report(&runner.op_fleet(&launch_request(ITEM, &work)));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let mut fleet = runner.fleet();
    let predecessor = fleet["lanes"][0]["launch"]["pid"].as_u64().unwrap() as u32;
    let bound = identity(&fleet["lanes"][0]);
    // Rows the marks leave as they stood: another kind, item, session or
    // launch beside this switch's.
    let other =
        json!({"launch": {"pid": 7, "start": "ticks:7"}, "launched_at": "2026-11-11T00:00:00Z"});
    let beside = |kind: &str, item: &str, session: &str, launch_identity: &Value| json!({"kind": kind, "item": item, "session_id": session, "launch_identity": launch_identity});
    let decoys = vec![
        beside("model-unavailable", ITEM, "current", &bound),
        beside("model-switched", "KEN-O", "current", &bound),
        beside("model-switched", ITEM, "earlier", &bound),
        beside("model-switched", ITEM, "current", &other),
    ];
    let own = decoys.len();
    switched(&mut fleet, false, decoys);
    runner.write_fleet(&fleet);

    let out = runner.op_fleet(&recovery("current", &bound));
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let job = answer["result"]["job"].clone();
    assert_eq!(job["launch"], "started", "{answer}");
    let again = runner.op_fleet(&recovery("current", &bound));
    assert_eq!(refusal(&again).0, "model-recovery-unbound");

    let deadline = Instant::now() + Duration::from_secs(120);
    let fleet = loop {
        let fleet = runner.fleet();
        if matches!(
            fleet["fleet_log"][own]["recovery"].as_str(),
            Some("replaced" | "failed")
        ) {
            break fleet;
        }
        assert!(
            Instant::now() < deadline,
            "the recovery never ended: {fleet}\n{}",
            std::fs::read_to_string(work.join(format!("model-recovery-{ITEM}.log")))
                .unwrap_or_default()
        );
        std::thread::sleep(Duration::from_millis(100));
    };
    if let Some(pid) = job["pid"].as_u64() {
        let deadline = Instant::now() + Duration::from_secs(30);
        while live(pid as u32) {
            assert!(Instant::now() < deadline, "the job outlived its marks");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    let log = fleet["fleet_log"].as_array().unwrap();
    assert_eq!(log[own]["recovery"], "replaced", "{log:?}");
    for row in &log[..own] {
        assert!(
            row.get("recovery").is_none(),
            "a row beside the switch marked: {row}"
        );
    }
    assert!(
        !live(predecessor),
        "the predecessor runs on beside its record"
    );
    let lane = &fleet["lanes"][0];
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(lane["model"], "claude-fable-5-1", "{lane}");
    assert_eq!(lane["effort"], "high", "{lane}");
    assert_ne!(
        lane["launch"]["pid"].as_u64().unwrap() as u32,
        predecessor,
        "the replacement is another harness"
    );
    let close = log.iter().find(|row| row["kind"] == "close").unwrap();
    assert_eq!(close["disposition"], "no-landing", "{close}");
    assert_eq!(close["reason"], "model-switch", "{close}");
}

/// The recovery that would reach the limit since the lane's last reset is
/// refused before anything stops, the switch spent and the limit's row
/// written: a `replaced` row counts, a `starting` one counts where its
/// replacement switched again under another launch, and a reset starts the
/// count again.
#[test]
fn the_nth_recovery_since_its_reset_is_refused_and_logged() {
    let other =
        json!({"launch": {"pid": 7, "start": "ticks:7"}, "launched_at": "2026-11-11T00:00:00Z"});
    let this = json!({"launch": {"pid": GONE_PID, "start": "ticks:1"},
                      "launched_at": "2026-11-12T10:00:00Z"});
    let row = |recovery: &str, launch_identity: &Value| {
        json!({"kind": "model-switched", "item": ITEM, "session_id": "earlier",
               "launch_identity": launch_identity, "recovery": recovery})
    };
    let reset = json!({"kind": "model-recovery-reset", "item": ITEM});
    let rows = [
        (
            "two since the reset",
            vec![
                row("replaced", &other),
                reset.clone(),
                row("replaced", &other),
                row("starting", &other),
            ],
            "3",
            "2",
        ),
        (
            "one since the reset",
            vec![
                row("replaced", &other),
                row("replaced", &other),
                reset.clone(),
                row("replaced", &other),
                row("failed", &other),
            ],
            "2",
            "1",
        ),
        (
            "another item's and this launch's own rows uncounted",
            vec![
                row("replaced", &other),
                json!({"kind": "model-switched", "item": "KEN-O", "session_id": "earlier",
                       "launch_identity": other, "recovery": "replaced"}),
                row("starting", &this),
            ],
            "2",
            "1",
        ),
    ];
    for (name, log, limit, recoveries) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-record");
        runner.init_fleet();
        let mut fleet = planted_lane(&runner, runner.state_dir());
        switched(&mut fleet, false, log);
        assert_eq!(identity(&fleet["lanes"][0]), this, "{name}");
        // Another item's lane, switched under the same launch, whose check
        // the claim leaves unstarted.
        let mut neighbour = fleet["lanes"][0].clone();
        neighbour["item"] = json!("KEN-O");
        fleet["lanes"].as_array_mut().unwrap().push(neighbour);
        runner.write_fleet(&fleet);
        let bound = identity(&fleet["lanes"][0]);
        let out = runner.op_fleet_env(
            &recovery("current", &bound),
            &[("ORCH_MODEL_RECOVERY_LIMIT", limit)],
        );
        let (key, fields) = refusal(&out);
        assert_eq!(key, "model-recovery-limit", "{name}: {}", stderr(&out));
        assert_eq!(field(&fields, "recoveries"), recoveries, "{name}");
        assert_eq!(field(&fields, "limit"), limit, "{name}");
        let fleet = runner.fleet();
        assert_eq!(
            fleet["lanes"][0]["model_check"]["recovery_started"], true,
            "{name}: the switch is spent"
        );
        assert_eq!(
            fleet["lanes"][1]["model_check"]["recovery_started"], false,
            "{name}: another item's switch as it stood"
        );
        let last = fleet["fleet_log"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()
            .clone();
        assert_eq!(last["kind"], "model-recovery-limit", "{name}: {last}");
        assert_eq!(last["recoveries"].to_string(), recoveries, "{name}");
        assert!(
            std::fs::symlink_metadata(
                runner
                    .state_dir()
                    .join(format!("model-recovery-{ITEM}.log"))
            )
            .is_err(),
            "{name}: no job started"
        );
    }
}

/// A recovery whose lane no longer runs the switched launch, whose check is
/// another session's, not a switch, bound to another launch, or whose
/// recovery already started, or for an item no lane runs, is refused
/// `model-recovery-unbound` with the record as it stood and no job.
#[test]
fn a_moved_launch_or_session_starts_no_recovery() {
    type Plant = fn(&mut Value);
    let rows: [(&str, &str, bool, Plant); 7] = [
        // A relaunch moved the lane on while the switch's check still names
        // the launch it was taken under.
        ("moved launch", "current", false, |lane| {
            lane["launched_at"] = json!("2026-11-12T11:00:00Z");
        }),
        ("moved process", "current", false, |lane| {
            lane["launch"] = json!({"pid": GONE_PID, "start": "ticks:2"});
        }),
        ("another session", "other", false, |_| {}),
        ("already started", "current", true, |_| {}),
        ("not a switch", "current", false, |lane| {
            lane["model_check"]["outcome"] = json!("unavailable");
        }),
        (
            "a check bound to another launch",
            "current",
            false,
            |lane| {
                lane["model_check"]["launch_identity"] = json!(
                    {"launch": {"pid": 7, "start": "ticks:7"}, "launched_at": "2026-11-11T00:00:00Z"}
                );
            },
        ),
        // The lane that runs the switched launch is another item's.
        ("no lane of the item", "current", false, |lane| {
            lane["item"] = json!("KEN-O");
        }),
    ];
    for (name, session, started, plant) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-record");
        runner.init_fleet();
        let mut fleet = planted_lane(&runner, runner.state_dir());
        switched(&mut fleet, started, Vec::new());
        let bound = identity(&fleet["lanes"][0]);
        plant(&mut fleet["lanes"][0]);
        runner.write_fleet(&fleet);
        let out = runner.op_fleet(&recovery(session, &bound));
        assert_eq!(
            refusal(&out).0,
            "model-recovery-unbound",
            "{name}: {}",
            stderr(&out)
        );
        let after = runner.fleet();
        assert_eq!(
            after["lanes"][0]["model_check"]["recovery_started"], started,
            "{name}: the check as it stood"
        );
        assert!(
            std::fs::symlink_metadata(
                runner
                    .state_dir()
                    .join(format!("model-recovery-{ITEM}.log"))
            )
            .is_err(),
            "{name}: no job started"
        );
    }
}

/// A record no relaunch can be composed from is refused by its cause before
/// anything stops: no model, no harness, no checkout, a checkout gone, a
/// job the launcher refused; a lane on `local` or no host is this
/// machine's. A hosted lane is refused before its switch is claimed, its
/// predecessor being its host's, and so is a setting the replacement's
/// launch would refuse or a recovery limit that is no count.
#[test]
fn an_unpreparable_record_is_refused_before_anything_stops() {
    type Plant = fn(&mut Value, &Path, &Path);
    let rows: [(&str, Plant, Settings, &str, &str, bool); 10] = [
        (
            "no model",
            |lane, _, _| {
                lane.as_object_mut().unwrap().remove("model");
            },
            &[],
            "model-recovery-unprepared",
            "model-unrecorded",
            true,
        ),
        (
            "no model on local",
            |lane, _, _| {
                lane.as_object_mut().unwrap().remove("model");
                lane["host"] = json!("local");
            },
            &[],
            "model-recovery-unprepared",
            "model-unrecorded",
            true,
        ),
        (
            "no model on no host",
            |lane, _, _| {
                lane.as_object_mut().unwrap().remove("model");
                lane["host"] = json!("");
            },
            &[],
            "model-recovery-unprepared",
            "model-unrecorded",
            true,
        ),
        (
            "no harness",
            |lane, _, _| {
                lane.as_object_mut().unwrap().remove("harness");
            },
            &[],
            "model-recovery-unprepared",
            "harness-unrecorded",
            true,
        ),
        (
            "no checkout",
            |lane, _, _| {
                lane.as_object_mut().unwrap().remove("mail_root");
            },
            &[],
            "model-recovery-unprepared",
            "checkout-unrecorded",
            true,
        ),
        (
            "checkout gone",
            |lane, root, _| lane["mail_root"] = json!(root.join("gone").display().to_string()),
            &[],
            "model-recovery-unprepared",
            "checkout-unavailable",
            true,
        ),
        // The job's record path is a directory, so the launcher cannot
        // write it and starts nothing.
        (
            "launcher refused",
            |_, _, state| {
                std::fs::create_dir(state.join(format!("model-recovery-{ITEM}.unit"))).unwrap();
            },
            &[],
            "model-recovery-unstarted",
            "record-unwritable",
            true,
        ),
        (
            "hosted",
            |lane, root, _| lane["host"] = json!(root.join("provider").display().to_string()),
            &[],
            "model-recovery-hosted",
            "",
            false,
        ),
        (
            "a launch setting refused",
            |_, _, _| {},
            &[("ORCH_LANE_OUTPUT", "loud")],
            "setting-invalid",
            "",
            false,
        ),
        (
            "a recovery limit that is no count",
            |_, _, _| {},
            &[("ORCH_MODEL_RECOVERY_LIMIT", "many")],
            "setting-invalid",
            "",
            false,
        ),
    ];
    for (name, plant, env, key, cause, spent) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-record");
        runner.init_fleet();
        let mut fleet = planted_lane(&runner, runner.state_dir());
        plant(&mut fleet["lanes"][0], dir.path(), runner.state_dir());
        switched(&mut fleet, false, Vec::new());
        runner.write_fleet(&fleet);
        let bound = identity(&fleet["lanes"][0]);
        let out = runner.op_fleet_env(&recovery("current", &bound), env);
        let (refused, fields) = refusal(&out);
        assert_eq!(refused, key, "{name}: {}", stderr(&out));
        assert!(
            field(&fields, "cause").starts_with(cause),
            "{name}: {fields:?}"
        );
        let after = runner.fleet();
        assert_eq!(
            after["lanes"][0]["model_check"]["recovery_started"], spent,
            "{name}: the claim"
        );
        assert_eq!(after["lanes"][0]["status"], "running", "{name}");
        assert!(
            after["fleet_log"]
                .as_array()
                .unwrap()
                .iter()
                .all(|row| row["kind"] != "close"),
            "{name}: nothing closed"
        );
        assert!(
            std::fs::symlink_metadata(
                runner
                    .state_dir()
                    .join(format!("model-recovery-{ITEM}.log"))
            )
            .is_err(),
            "{name}: no job started"
        );
    }
}

/// A record naming no class, or no reason for it, is refused by its cause
/// before anything stops, as one naming no model: the relaunch keeps the
/// record's pair, so its launch would refuse once the close had retired the
/// predecessor. Nothing is composed, closed or started.
#[test]
fn a_record_naming_no_class_or_reason_is_refused_before_anything_stops() {
    type Plant = fn(&mut Value);
    let rows: [(&str, Plant); 3] = [
        ("no class", |lane| {
            lane.as_object_mut().unwrap().remove("class");
        }),
        ("no reason", |lane| {
            lane.as_object_mut().unwrap().remove("class_reason");
        }),
        ("a blank reason", |lane| lane["class_reason"] = json!(" ")),
    ];
    for (name, plant) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-record");
        runner.init_fleet();
        let mut fleet = planted_lane(&runner, runner.state_dir());
        plant(&mut fleet["lanes"][0]);
        switched(&mut fleet, false, Vec::new());
        runner.write_fleet(&fleet);
        let bound = identity(&fleet["lanes"][0]);
        let out = runner.op_fleet(&recovery("current", &bound));
        assert_eq!(
            reply(&out),
            json!({
                "protocol": "orch-runtime-v1",
                "ok": false,
                "refusal": {
                    "key": "model-recovery-unprepared",
                    "fields": [["item", ITEM], ["cause", "class-unrecorded"]],
                    "text": "refused model-recovery-unprepared: [(\"item\", \"KEN-R\"), (\"cause\", \"class-unrecorded\")]",
                },
            }),
            "{name}: {}",
            stderr(&out)
        );
        let after = runner.fleet();
        let lane = &after["lanes"][0];
        assert_eq!(lane["model_check"]["recovery_started"], true, "{name}");
        assert_eq!(lane["status"], "running", "{name}");
        assert_eq!(lane["launch"], fleet["lanes"][0]["launch"], "{name}");
        assert!(
            after["fleet_log"]
                .as_array()
                .unwrap()
                .iter()
                .all(|row| row["kind"] != "close"),
            "{name}: nothing closed"
        );
        for suffix in ["md", "close.json", "json", "log", "unit"] {
            let file = runner
                .state_dir()
                .join(format!("model-recovery-{ITEM}.{suffix}"));
            assert!(
                std::fs::symlink_metadata(&file).is_err(),
                "{name}: {}",
                file.display()
            );
        }
    }
}

/// The item's record a hosted lane's switch wrote: the handoff of
/// `handoff_session` and the check of `current` bound to `bound`.
fn item_record(runner: &Runner, handoff_session: &str, bound: &Value) -> std::path::PathBuf {
    let out = runner.run(&["state", "init", "--item", ITEM]);
    assert!(out.status.success(), "init: {}", stderr(&out));
    let path = runner
        .state_dir()
        .join(format!("workflow-state-{ITEM}.json"));
    let mut doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    doc["handoff"] = json!({"session_id": handoff_session, "cause": "model-switched"});
    doc["model_checks"] = json!({"current": {
        "outcome": "switched", "session_id": "current", "launch_identity": bound,
        "recovery_started": true,
    }});
    std::fs::write(&path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    path
}

/// The leader a gone predecessor's group record names.
fn gone_leader() -> Value {
    json!({"pid": GONE_PID, "start": "ticks:1"})
}

fn predecessor_stop(file: &Path, launch_identity: &Value, leader: &Value, job: bool) -> Value {
    let mut request = json!({
        "op": "stop-model-predecessor",
        "session": "current",
        "launch_identity": launch_identity,
        "file": file.display().to_string(),
        "leader": leader,
    });
    if job {
        request["job"] = json!(true);
    }
    request
}

/// The stop job's own run over a group record it cannot stop by: a record
/// it cannot read fails the stop, kept on the handoff as
/// `{cause, pid, launch, exit, at}` only where the handoff is still this
/// session's and its check is bound to the stopped launch; a group already
/// gone is a stop and keeps nothing.
#[test]
fn a_failed_predecessor_stop_is_kept_on_the_handoff_bound_to_its_launch() {
    let bound =
        json!({"launch": {"pid": 41, "start": "ticks:41"}, "launched_at": "2026-11-12T10:00:00Z"});
    let other =
        json!({"launch": {"pid": 42, "start": "ticks:42"}, "launched_at": "2026-11-12T11:00:00Z"});
    let unreadable = "not a group record";
    let gone = json!({"pid": GONE_PID, "start": "ticks:1"}).to_string();
    let rows = [
        (
            "bound",
            "current",
            &bound,
            unreadable,
            true,
            Some("record-shape"),
        ),
        (
            "another session's handoff",
            "other",
            &bound,
            unreadable,
            false,
            Some("record-shape"),
        ),
        (
            "another launch's check",
            "current",
            &other,
            unreadable,
            false,
            Some("record-shape"),
        ),
        (
            "already gone",
            "current",
            &bound,
            gone.as_str(),
            false,
            None,
        ),
    ];
    for (name, handoff, check, group, kept, cause) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-record");
        let path = item_record(&runner, handoff, check);
        let file = runner.state_dir().join("lane-host-pid");
        std::fs::write(&file, group).unwrap();
        let request = runner.state_dir().join("stop.json");
        std::fs::write(
            &request,
            predecessor_stop(&file, &bound, &gone_leader(), true).to_string(),
        )
        .unwrap();
        let out = runner.run(&[
            "op",
            "--file",
            &path.display().to_string(),
            "--request",
            &request.display().to_string(),
        ]);
        match cause {
            Some(cause) => {
                let (key, fields) = refusal(&out);
                assert_eq!(
                    key,
                    "model-predecessor-unstopped",
                    "{name}: {}",
                    stderr(&out)
                );
                assert_eq!(field(&fields, "cause"), cause, "{name}");
            }
            None => assert_eq!(reply(&out)["ok"], true, "{name}: {}", stderr(&out)),
        }
        let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let failure = &doc["handoff"]["stop_failure"];
        if kept {
            assert_eq!(failure["cause"], "record-shape", "{name}: {doc}");
            assert_eq!(failure["pid"], Value::Null, "{name}");
            assert_eq!(failure["launch"], bound["launch"], "{name}");
            assert_eq!(failure["exit"], 1, "{name}");
            assert!(failure["at"].is_string(), "{name}");
        } else {
            assert!(failure.is_null(), "{name}: {doc}");
        }
    }
}

/// A predecessor stop whose job cannot start, or whose stop's grace the
/// settings refuse, is refused to its caller with no job and nothing kept.
#[test]
fn a_predecessor_stop_that_cannot_start_is_refused_to_its_caller() {
    let bound =
        json!({"launch": {"pid": 41, "start": "ticks:41"}, "launched_at": "2026-11-12T10:00:00Z"});
    type Plant = fn(&Path);
    let rows: [(&str, Plant, Settings, &str, &str); 2] = [
        // The job's record path is a directory, so the launcher cannot
        // write it and starts nothing.
        (
            "launcher refused",
            |state| {
                std::fs::create_dir(
                    state.join(format!("workflow-state-{ITEM}.predecessor-stop.unit")),
                )
                .unwrap();
            },
            &[],
            "model-predecessor-unstarted",
            "record-unwritable",
        ),
        (
            "grace refused",
            |_| {},
            &[("ORCH_LANE_CLOSE_SECS", "never")],
            "setting-invalid",
            "",
        ),
    ];
    for (name, plant, env, key, cause) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-record");
        let path = item_record(&runner, "current", &bound);
        plant(runner.state_dir());
        let file = runner.state_dir().join("lane-host-pid");
        let request = runner.state_dir().join("stop.json");
        std::fs::write(
            &request,
            predecessor_stop(&file, &bound, &gone_leader(), false).to_string(),
        )
        .unwrap();
        let out = runner.run_env(
            &[
                "op",
                "--file",
                &path.display().to_string(),
                "--request",
                &request.display().to_string(),
            ],
            env,
        );
        let (refused, fields) = refusal(&out);
        assert_eq!(refused, key, "{name}: {}", stderr(&out));
        assert!(
            field(&fields, "cause").starts_with(cause),
            "{name}: {fields:?}"
        );
        assert!(
            std::fs::symlink_metadata(
                runner
                    .state_dir()
                    .join(format!("workflow-state-{ITEM}.predecessor-stop.log"))
            )
            .is_err(),
            "{name}: no job started"
        );
        let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert!(doc["handoff"]["stop_failure"].is_null(), "{name}: {doc}");
    }
}

/// The caller of the predecessor stop runs inside the group it stops, as a
/// turn end runs in its harness's: its request starts the stop's job apart
/// from that group and answers at once; the job stops every member of the
/// recorded group by its identity and nothing outside it.
#[test]
fn the_predecessor_stopper_runs_outside_the_group_it_stops() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-record");
    let work = runner.state_dir().to_path_buf();
    let out = program("git")
        .args(["-C", &work.display().to_string(), "init", "-q"])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    install_entry(&work);
    let bound =
        json!({"launch": {"pid": 41, "start": "ticks:41"}, "launched_at": "2026-11-12T10:00:00Z"});
    let path = item_record(&runner, "current", &bound);
    let file = work.join("lane-host-pid");
    let request = work.join("stop.json");
    let mut bystander = program("sleep").arg("60").spawn().unwrap();
    let member = work.join("member.pid");
    let answer = work.join("reply.json");
    let go = work.join("go");
    let mut command = program(agent_runtime());
    runner.apply_env(&mut command);
    let mut group = command
        .args([
            "process",
            "lead",
            "--file",
            &file.display().to_string(),
            "--",
        ])
        .args([
            "bash",
            "-c",
            "sleep 60 & printf '%s' \"$!\" > \"$1\"; while [ ! -e \"$2\" ]; do sleep 0.05; done; shift 2; \"$@\" > \"$0\"; wait",
        ])
        .arg(&answer)
        .arg(&member)
        .arg(&go)
        .arg(binary())
        .args([
            "--no-private-env",
            "--state-dir",
            &work.display().to_string(),
        ])
        .args(["op", "--file", &path.display().to_string()])
        .args(["--request", &request.display().to_string()])
        .current_dir(&work)
        .spawn()
        .unwrap();
    // The caller's request names the leader its member read answered: the
    // one the group's record names once the lead wrote it.
    let deadline = Instant::now() + Duration::from_secs(20);
    let leader: Value = loop {
        if let Ok(text) = std::fs::read_to_string(&file)
            && let Ok(leader) = serde_json::from_str(&text)
        {
            break leader;
        }
        assert!(
            Instant::now() < deadline,
            "the group's record was never written"
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    std::fs::write(
        &request,
        predecessor_stop(&file, &bound, &leader, false).to_string(),
    )
    .unwrap();
    std::fs::write(&go, "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    let status = loop {
        if let Some(status) = group.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "the group was never stopped");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(
        !status.success(),
        "the leader ended by the stop: {status:?}"
    );
    let sleeper: u32 = std::fs::read_to_string(&member).unwrap().parse().unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    while live(sleeper) {
        assert!(Instant::now() < deadline, "a member outlived the stop");
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(
        live(bystander.id()),
        "a process outside the group was stopped"
    );
    bystander.kill().unwrap();
    bystander.wait().unwrap();
    let log = work.join(format!("workflow-state-{ITEM}.predecessor-stop.log"));
    assert!(
        std::fs::symlink_metadata(&log).is_ok(),
        "the stop ran as its own job"
    );
    // The caller is a member: where it answered before the stop reached it,
    // its answer is the job's start.
    if let Ok(text) = std::fs::read_to_string(&answer)
        && !text.is_empty()
    {
        let answered: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(answered["result"]["job"]["launch"], "started", "{answered}");
    }
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(doc["handoff"]["stop_failure"].is_null(), "{doc}");
}

/// The stop job's own run where the group's record names another leader
/// than the one the switch read, as a replacement's launch writes it once
/// the predecessor's group is gone: it stops nothing, and the failure is
/// `identity-stale`, kept on the handoff.
#[test]
fn a_predecessor_stop_whose_record_names_another_leader_stops_nothing() {
    use std::os::unix::process::CommandExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-record");
    let bound =
        json!({"launch": {"pid": 41, "start": "ticks:41"}, "launched_at": "2026-11-12T10:00:00Z"});
    let path = item_record(&runner, "current", &bound);
    let replacement = Owned(
        program("sleep")
            .arg("600")
            .process_group(0)
            .spawn()
            .unwrap(),
    );
    let file = runner.state_dir().join("lane-host-pid");
    std::fs::write(
        &file,
        json!({"pid": replacement.pid(), "start": start_of(replacement.pid())}).to_string(),
    )
    .unwrap();
    let request = runner.state_dir().join("stop.json");
    std::fs::write(
        &request,
        predecessor_stop(&file, &bound, &gone_leader(), true).to_string(),
    )
    .unwrap();
    let out = runner.run(&[
        "op",
        "--file",
        &path.display().to_string(),
        "--request",
        &request.display().to_string(),
    ]);
    let (key, fields) = refusal(&out);
    assert_eq!(key, "model-predecessor-unstopped", "{}", stderr(&out));
    assert_eq!(field(&fields, "cause"), "identity-stale");
    assert!(
        live(replacement.pid()),
        "the replacement's group was stopped"
    );
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(
        doc["handoff"]["stop_failure"]["cause"], "identity-stale",
        "{doc}"
    );
}

/// The runtime's entry a recovery's job runs, as a stand-in installed
/// where the checkout at `root` names it: it records each call at `calls`,
/// answers the close request with `close` and the launch request with
/// `launch` and runs neither, refuses the `starting` mark where `starting`
/// is not 0, and hands every other mark to the binary.
fn install_stand_in(root: &Path, calls: &Path, close: &str, starting: &str, launch: &str) {
    let scripts = root.join(".agents/skills/orch/scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    write_executable(
        &scripts.join("orch-runtime"),
        format!(
            "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '{calls}'\ncase \"$*\" in\n  *.close.json) exit {close} ;;\n  *'\"mark\":\"starting\"'*) [ {starting} -eq 0 ] || exit {starting} ;;\n  *'--effect-exit --request '*) exit {launch} ;;\nesac\nexec '{binary}' --no-private-env \"$@\"\n",
            calls = calls.display(),
            binary = binary().display(),
        ),
    );
}

/// A recovery's job asks the launch only after its close confirmed and its
/// `starting` mark was written; a launch whose outcome is still open leaves
/// the switch `starting` for its intent's reconcile, and a failed one marks
/// it `failed`.
#[test]
fn a_recovery_job_launches_only_after_its_close_and_marks_what_the_launch_met() {
    // The close's, the `starting` mark's and the launch's statuses, the
    // calls the entry answers, and the switch's mark at the end.
    type Case = (&'static str, &'static str, &'static str, &'static str);
    let rows: [(Case, usize, Option<&str>); 4] = [
        (("a close that failed", "1", "0", "0"), 1, None),
        (("a starting mark refused", "0", "1", "0"), 2, None),
        (("a launch still open", "0", "0", "75"), 3, Some("starting")),
        (("a launch that failed", "0", "0", "1"), 4, Some("failed")),
    ];
    for ((name, close, starting, launch), asked, mark) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-record");
        runner.init_fleet();
        let work = runner.state_dir().to_path_buf();
        let calls = work.join("entry-calls");
        install_stand_in(&work, &calls, close, starting, launch);
        let mut fleet = planted_lane(&runner, &work);
        switched(&mut fleet, false, Vec::new());
        runner.write_fleet(&fleet);
        let bound = identity(&fleet["lanes"][0]);
        let out = runner.op_fleet(&recovery("current", &bound));
        let answer = reply(&out);
        assert_eq!(answer["ok"], true, "{name}: {}", stderr(&out));
        let pid = answer["result"]["job"]["pid"]
            .as_u64()
            .unwrap_or_else(|| panic!("{name}: {answer}")) as u32;
        let deadline = Instant::now() + Duration::from_secs(60);
        while live(pid) {
            assert!(Instant::now() < deadline, "{name}: the job never ended");
            std::thread::sleep(Duration::from_millis(50));
        }
        let log = std::fs::read_to_string(work.join(format!("model-recovery-{ITEM}.log")))
            .unwrap_or_default();
        let lines: Vec<String> = std::fs::read_to_string(&calls)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect();
        assert_eq!(lines.len(), asked, "{name}: {lines:?}\n{log}");
        let launched = lines
            .iter()
            .any(|line| line.ends_with(&format!("model-recovery-{ITEM}.json")));
        assert_eq!(launched, asked >= 3, "{name}: {lines:?}");
        if close != "0" {
            assert!(
                log.contains(&format!("model-recovery=stop-failed exit={close}")),
                "{name}: {log}"
            );
        }
        let fleet = runner.fleet();
        let row = &fleet["fleet_log"][0];
        assert_eq!(row["recovery"].as_str(), mark, "{name}: {row}\n{log}");
    }
}

/// A recovery relaunches on the account its record names, and a record
/// whose account is empty names none, so the launch chooses one as for a
/// record naming no account. The entry fails the close, so nothing
/// launches.
#[test]
fn a_recorded_empty_account_names_no_account_on_the_relaunch() {
    let rows = [
        (
            "a named account",
            "/home/me/.aclaude",
            Some("/home/me/.aclaude"),
        ),
        ("an empty account", "", None),
    ];
    for (name, account, named) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-record");
        runner.init_fleet();
        let work = runner.state_dir().to_path_buf();
        install_stand_in(&work, &work.join("entry-calls"), "1", "0", "0");
        let mut fleet = planted_lane(&runner, &work);
        fleet["lanes"][0]["account"] = json!(account);
        switched(&mut fleet, false, Vec::new());
        runner.write_fleet(&fleet);
        let bound = identity(&fleet["lanes"][0]);
        let out = runner.op_fleet(&recovery("current", &bound));
        let answer = reply(&out);
        assert_eq!(answer["ok"], true, "{name}: {}", stderr(&out));
        let pid = answer["result"]["job"]["pid"]
            .as_u64()
            .unwrap_or_else(|| panic!("{name}: {answer}")) as u32;
        let deadline = Instant::now() + Duration::from_secs(60);
        while live(pid) {
            assert!(Instant::now() < deadline, "{name}: the job never ended");
            std::thread::sleep(Duration::from_millis(50));
        }
        let request: Value = serde_json::from_str(
            &std::fs::read_to_string(work.join(format!("model-recovery-{ITEM}.json"))).unwrap(),
        )
        .unwrap();
        assert_eq!(
            request.get("account").and_then(Value::as_str),
            named,
            "{name}: {request}"
        );
        assert_eq!(runner.fleet()["lanes"][0]["status"], "running", "{name}");
    }
}

/// The turn end's in-process start admits its request under its settings
/// as the command does, before its claim: a setting the replacement's
/// launch would refuse leaves the switch unspent. The limit of one would
/// refuse the claim at once, so a start that claimed first spends it.
#[test]
fn the_turn_ends_start_judges_its_settings_before_it_claims() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-record");
    runner.init_fleet();
    let state = runner.state_dir().to_path_buf();
    let mut fleet = planted_lane(&runner, &state);
    switched(&mut fleet, false, Vec::new());
    runner.write_fleet(&fleet);
    let environment: Vec<(OsString, OsString)> = [
        ("ORCH_LANE_OUTPUT", "loud"),
        ("ORCH_MODEL_RECOVERY_LIMIT", "1"),
        (
            "AGENT_RUNTIME_ACCOUNT_STATE_DIR",
            &*state.join("tmp/oversee-watch").display().to_string(),
        ),
    ]
    .iter()
    .map(|(k, v)| (OsString::from(k), OsString::from(v)))
    .collect();
    let settings = settings::load(
        &Roots {
            project: state.clone(),
            common: state.clone(),
        },
        &environment,
        &settings::Flags {
            state_dir: Some(state.clone()),
            private_env: false,
        },
    )
    .unwrap();
    let request = RecoverLaneModel {
        item: ITEM.to_owned(),
        session: "current".to_owned(),
        launch_identity: identity(&fleet["lanes"][0]),
        mark: None,
        limit: None,
    };
    let env = Env {
        now_secs: 1_800_000_000,
        now_nanos: 1_800_000_000_u128 * 1_000_000_000,
        nonce: 1,
        owner: None,
    };
    let refused = lane_model::start(
        &settings,
        &state.join("workflow-state-oversee.json"),
        &request,
        &env,
        Locking::FLOCK,
    )
    .unwrap_err();
    assert_eq!(refused.key(), "setting-invalid", "{refused:?}");
    let after = runner.fleet();
    assert_eq!(
        after["lanes"][0]["model_check"]["recovery_started"], false,
        "the switch unspent"
    );
    assert!(
        after["fleet_log"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row["kind"] != "model-recovery-limit"),
        "{after}"
    );
}

/// The stop job's own run over a group record it cannot stop by, for an
/// item whose record no longer stands: the failure has nowhere to be kept,
/// so the job answers `model-predecessor-unrecorded` with the stop's cause
/// and the store's refusal, and writes no record.
#[test]
fn a_predecessor_stop_whose_item_record_is_gone_is_refused_unrecorded() {
    let bound =
        json!({"launch": {"pid": 41, "start": "ticks:41"}, "launched_at": "2026-11-12T10:00:00Z"});
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-record");
    let path = runner
        .state_dir()
        .join(format!("workflow-state-{ITEM}.json"));
    let file = runner.state_dir().join("lane-host-pid");
    std::fs::write(&file, "not a group record").unwrap();
    let request = runner.state_dir().join("stop.json");
    std::fs::write(
        &request,
        predecessor_stop(&file, &bound, &gone_leader(), true).to_string(),
    )
    .unwrap();
    let out = runner.run(&[
        "op",
        "--file",
        &path.display().to_string(),
        "--request",
        &request.display().to_string(),
    ]);
    let file = file.display().to_string();
    let store = format!("{}: no state file", path.display());
    let fields = [
        ("file", file.as_str()),
        ("cause", "record-shape"),
        ("pid", "none"),
        ("exit", "1"),
        ("store", store.as_str()),
    ];
    assert_eq!(
        reply(&out),
        json!({
            "protocol": "orch-runtime-v1",
            "ok": false,
            "refusal": {
                "key": "model-predecessor-unrecorded",
                "fields": fields,
                "text": format!("refused model-predecessor-unrecorded: {fields:?}"),
            },
        }),
        "{}",
        stderr(&out)
    );
    assert!(
        std::fs::symlink_metadata(&path).is_err(),
        "a record written for a gone item"
    );
}
