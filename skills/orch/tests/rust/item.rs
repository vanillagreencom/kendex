//! The item transitions: rounds, validation admission, accepted results
//! with their outcome and end, a round's admitted runs reconciled against
//! the host, the verification record and the handoff record. Each row
//! applies the library's operations to the legacy-shaped item fixture
//! beside this file under an injected clock; the last rows run the built
//! binary so the wire names of the new fields are the ones a workflow
//! writes.
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests hold owned children and wait on real time for them"
)]

use std::fs::{self, File};
use std::path::{Path, PathBuf};
mod support;

use std::process::{Child, Command, Output};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, UNIX_EPOCH};

use orch_runtime::error::Error;
use orch_runtime::ops::{
    AcceptResult, Applied, Attempt, BeginRound, EndSource, Env, ReconcileRound, RecordHandoff,
    RecordValidationAdmission, RecordVerification, Relaunch, Report, Request, ResumeHandoff,
    RoundKind, RunCause, RunState, apply,
};
use orch_runtime::state::{Document, ItemState, Locking, Record, Stage, StageKind, StageOutcome};
use serde_json::{Value, json};

const ITEM: &str = include_str!("fixtures/workflow-state-KEN-4687.json");
/// The fixture's open dev round and its start.
const ROUND: &str = "1769600000123456789-1837";
const ROUND_START: u64 = 1_769_600_000;
const NOW_SECS: u64 = 1_769_700_000;
const NOW_NANOS: u128 = 1_769_700_000_123_456_789;
const BASE_NONCE: u32 = 4242;
const LOCK: Locking = Locking::FLOCK;
/// The fixture's recorded worktree.
const WORKTREE: &str = "/home/u/dev/.worktrees/kendex/ken-4687";

/// The base stamp a row mints with: `2026-01-29T15:20:00Z`, nonce 4242.
fn env() -> Env {
    Env {
        now_secs: NOW_SECS,
        now_nanos: NOW_NANOS,
        nonce: BASE_NONCE,
        owner: None,
    }
}

fn at(now_secs: u64) -> Env {
    Env { now_secs, ..env() }
}

/// The nonces `run` mints: one per call, as one process mints one `Env`
/// per request, so two calls never replay a stamp.
static NONCES: AtomicU32 = AtomicU32::new(BASE_NONCE + 1);

/// Apply `request` as one call of the runtime at `now_secs`, with a fresh
/// nonce.
fn run_at(path: &Path, request: &Request, now_secs: u64) -> Result<Applied, Error> {
    let env = Env {
        nonce: NONCES.fetch_add(1, Ordering::Relaxed),
        ..at(now_secs)
    };
    apply(path, request, &env, LOCK)
}

fn run(path: &Path, request: &Request) -> Result<Applied, Error> {
    run_at(path, request, NOW_SECS)
}

fn item_file(dir: &Path) -> PathBuf {
    let path = dir.join("workflow-state-KEN-4687.json");
    fs::write(&path, ITEM).unwrap();
    path
}

fn object(path: &Path) -> Document {
    match serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap() {
        Value::Object(map) => map,
        other => panic!("not an object: {other}"),
    }
}

fn item(path: &Path) -> ItemState {
    ItemState::view(path, &object(path)).unwrap()
}

fn keys(doc: &Document) -> Vec<String> {
    doc.keys().cloned().collect()
}

fn begin(kind: RoundKind) -> Request {
    Request::BeginRound(BeginRound { kind })
}

fn admit(round: &str, run_dir: Option<&str>) -> Request {
    Request::RecordValidationAdmission(RecordValidationAdmission {
        round_id: round.into(),
        run_dir: run_dir.map(str::to_owned),
        attempt: Attempt::Current,
    })
}

fn admit_next(round: &str) -> Request {
    Request::RecordValidationAdmission(RecordValidationAdmission {
        round_id: round.into(),
        run_dir: None,
        attempt: Attempt::Next,
    })
}

fn admitted(applied: Applied) -> orch_runtime::ops::ValidationAdmitted {
    let Report::RecordValidationAdmission(a) = applied.report else {
        panic!("{:?}", applied.report)
    };
    a
}

fn accept(
    round: &str,
    run_dir: Option<&str>,
    outcome: StageOutcome,
    end: Option<&Path>,
) -> Request {
    Request::AcceptResult(AcceptResult {
        round_id: round.into(),
        run_dir: run_dir.map(str::to_owned),
        outcome,
        end: end.map(|from_artifact| EndSource {
            from_artifact: from_artifact.to_path_buf(),
        }),
    })
}

/// A file whose modification time is `mtime` epoch seconds: the artifact an
/// acceptance rests on.
fn artifact(dir: &Path, name: &str, mtime: u64) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, "{}").unwrap();
    File::open(&path)
        .unwrap()
        .set_modified(UNIX_EPOCH + Duration::from_secs(mtime))
        .unwrap();
    path
}

fn handoff_with(
    round: Option<&str>,
    relaunch: Option<Relaunch>,
    written_at: Option<&str>,
    remaining: &str,
    supersede: bool,
) -> Request {
    Request::RecordHandoff(Box::new(RecordHandoff {
        supersede,
        round_id: round.map(str::to_owned),
        merged: vec!["#2714".into()],
        remaining: vec![remaining.into()],
        branch: Some("rebuild/orch-architecture".into()),
        worktree: Some(WORKTREE.into()),
        open_pr: Value::Null,
        traps: vec!["the guard chain refuses the branch under main's scripts".into()],
        context: json!({"decision": "handoff", "source": "native"}),
        relaunch,
        written_at: written_at.map(str::to_owned),
    }))
}

fn handoff(round: Option<&str>, relaunch: Option<Relaunch>, written_at: Option<&str>) -> Request {
    handoff_with(round, relaunch, written_at, "merge-pr § 5 step 3", false)
}

fn resume() -> Request {
    Request::ResumeHandoff(ResumeHandoff {})
}

fn reconcile(round: &str) -> Request {
    Request::ReconcileRound(ReconcileRound {
        round_id: round.into(),
    })
}

fn validate_stages(path: &Path) -> Vec<Stage> {
    item(path)
        .stages
        .into_iter()
        .filter(|s| s.kind == StageKind::Validate)
        .collect()
}

/// Decision 33: an operation patches only the keys it writes.
#[test]
fn begin_round_mints_supersedes_and_opens_in_one_write() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let before = object(&path);
    let applied = apply(&path, &begin(RoundKind::Dev), &env(), LOCK).unwrap();
    let Report::BeginRound(begun) = &applied.report else {
        panic!("{:?}", applied.report)
    };
    assert_eq!(begun.round_id, "1769700000123456789-4242");
    assert_eq!(begun.superseded, vec![Some(ROUND.to_owned())]);
    let after = object(&path);
    assert_eq!(keys(&after), keys(&before), "top-level key sequence");
    for (key, value) in &before {
        if key != "dev_round_id" && key != "stages" {
            assert_eq!(&after[key], value, "{key}");
        }
    }
    let body = item(&path);
    assert_eq!(body.dev_round_id.as_deref(), Some(begun.round_id.as_str()));
    assert_eq!(body.stages.len(), 2);
    assert_eq!(body.stages[0].end, Some(NOW_SECS));
    assert_eq!(body.stages[0].superseded, Some(true));
    assert_eq!(
        keys(after["stages"][0].as_object().unwrap()),
        ["kind", "round_id", "start", "end", "superseded"]
    );
    assert_eq!(
        keys(after["stages"][1].as_object().unwrap()),
        ["kind", "round_id", "start", "end"]
    );
    assert_eq!(body.stages[1].kind, StageKind::Dev);
    assert_eq!(body.stages[1].start, NOW_SECS);
    assert_eq!(body.stages[1].end, None);
    // A review round leaves the dev stage open.
    apply(&path, &begin(RoundKind::Review), &env(), LOCK).unwrap();
    let body = item(&path);
    assert_eq!(
        body.review_round_id.as_deref(),
        Some("1769700000123456789-4242")
    );
    assert_eq!(body.stages.len(), 3);
    assert_eq!(body.stages[1].end, None);
    assert_eq!(body.stages[2].kind, StageKind::Review);
}

/// Decision 100: the runtime mints the run's identity at admission, before
/// any runner starts, once per round. A repeat of the request, whatever
/// clock or nonce the call carries, returns the open admission and writes
/// nothing; `attempt: next` mints the rerun beside it; with no open
/// admission a plain request mints again.
#[test]
fn admission_is_idempotent_per_round_and_mints_the_next_attempt_on_request() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let err = run(&path, &admit("no-such-round", None)).unwrap_err();
    assert_eq!(err.key(), "round-unknown");
    assert_eq!(validate_stages(&path).len(), 0, "a refusal writes no stage");

    let a = admitted(apply(&path, &admit(ROUND, None), &env(), LOCK).unwrap());
    assert!(a.minted);
    assert!(a.admitted_now);
    assert_eq!(a.run_id, "20260129T152000Z-4242");
    assert_eq!(
        a.run_dir,
        format!("{WORKTREE}/tmp/dev-validate-20260129T152000Z-4242")
    );
    assert_eq!(a.start, NOW_SECS);
    // The id fits dev-validate-run's --run-id grammar and the run index
    // grammar lane-gitfile.sh reads (`^dev-validate-[A-Za-z0-9-]+$`).
    let (stamp, nonce) = a.run_id.split_once('-').unwrap();
    assert_eq!(stamp.len(), 16);
    assert!(stamp[..8].bytes().all(|b| b.is_ascii_digit()));
    assert_eq!(&stamp[8..9], "T");
    assert!(stamp[9..15].bytes().all(|b| b.is_ascii_digit()));
    assert_eq!(&stamp[15..], "Z");
    assert!(nonce.bytes().all(|b| b.is_ascii_alphanumeric()));
    let doc = object(&path);
    let rows = doc["stages"].as_array().unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(
        keys(rows[1].as_object().unwrap()),
        ["kind", "round_id", "start", "end", "run_dir"]
    );
    let stages = validate_stages(&path);
    assert_eq!(stages.len(), 1);
    assert_eq!(stages[0].round_id.as_deref(), Some(ROUND));
    assert_eq!(stages[0].run_dir.as_deref(), Some(a.run_dir.as_str()));
    assert_eq!(stages[0].end, None, "the stage stays open until the result");
    assert_eq!(stages[0].outcome, None);

    // The replayed delegation command, later and with another nonce, is
    // the same operation: the open admission, nothing minted or written.
    let same = admitted(run_at(&path, &admit(ROUND, None), NOW_SECS + 120).unwrap());
    assert!(!same.admitted_now);
    assert!(!same.minted);
    assert_eq!(same.run_id, a.run_id);
    assert_eq!(same.run_dir, a.run_dir);
    assert_eq!(same.start, NOW_SECS, "the first admission's start stands");
    assert_eq!(validate_stages(&path), stages, "the repeat wrote nothing");

    // The rerun the dev gate permits is the next attempt, asked for by
    // name: its own identity beside the open one.
    let b = admitted(run_at(&path, &admit_next(ROUND), NOW_SECS + 120).unwrap());
    assert!(b.admitted_now);
    assert!(b.minted);
    assert_ne!(b.run_dir, a.run_dir);
    assert_eq!(b.start, NOW_SECS + 120);
    let stages = validate_stages(&path);
    assert_eq!(stages.len(), 2);
    assert_eq!(stages[0].end, None);
    assert_eq!(stages[1].end, None);
    // Two next attempts in one second differ by their nonce, so neither
    // directory is the other's.
    let c = admitted(run_at(&path, &admit_next(ROUND), NOW_SECS + 120).unwrap());
    assert_ne!(c.run_id, b.run_id);
    assert_eq!(&c.run_id[..17], &b.run_id[..17], "same stamp");
    assert_eq!(validate_stages(&path).len(), 3);
    // A plain repeat now names the newest open attempt.
    let newest = admitted(run_at(&path, &admit(ROUND, None), NOW_SECS + 130).unwrap());
    assert!(!newest.admitted_now);
    assert_eq!(newest.run_dir, c.run_dir);

    // Once every admitted run of the round is closed, a plain request has
    // no open admission to return and mints again.
    for (run_dir, outcome) in [
        (&a.run_dir, StageOutcome::Fail),
        (&b.run_dir, StageOutcome::Lost),
        (&c.run_dir, StageOutcome::Fail),
    ] {
        run_at(
            &path,
            &accept(ROUND, Some(run_dir), outcome, None),
            NOW_SECS + 150,
        )
        .unwrap();
    }
    let d = admitted(run_at(&path, &admit(ROUND, None), NOW_SECS + 200).unwrap());
    assert!(d.admitted_now);
    assert!(d.minted);
    assert_eq!(d.start, NOW_SECS + 200);
    let stages = validate_stages(&path);
    assert_eq!(stages.len(), 4);
    assert_eq!(stages[0].outcome, Some(StageOutcome::Fail));
    assert_eq!(stages[3].end, None);

    // An item recording no worktree can name no directory: refused, with
    // nothing written.
    let bare = dir.path().join("workflow-state-KEN-1.json");
    fs::write(
        &bare,
        ITEM.replacen(
            &format!("\"worktree\": \"{WORKTREE}\""),
            "\"worktree\": \"\"",
            1,
        ),
    )
    .unwrap();
    let text = fs::read_to_string(&bare).unwrap();
    let err = run(&bare, &admit(ROUND, None)).unwrap_err();
    assert_eq!(err.key(), "worktree-unrecorded");
    assert_eq!(fs::read_to_string(&bare).unwrap(), text);
}

/// The legacy order: the runner minted the directory and the caller names
/// it. The id is read from the name, the caller's identity wins, and a
/// repeat of the same directory is a no-op with the same reply shape.
#[test]
fn a_runner_named_run_dir_is_admitted_as_given_and_repeats_as_a_no_op() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let given = "/w/tmp/dev-validate-20260129T152000Z-777";
    let a = admitted(apply(&path, &admit(ROUND, Some(given)), &env(), LOCK).unwrap());
    assert!(a.admitted_now);
    assert!(!a.minted, "the caller's identity won");
    assert_eq!(a.run_dir, given);
    assert_eq!(a.run_id, "20260129T152000Z-777");
    assert_eq!(a.start, NOW_SECS);
    let b = admitted(run_at(&path, &admit(ROUND, Some(given)), NOW_SECS + 60).unwrap());
    assert!(!b.admitted_now);
    assert!(!b.minted);
    assert_eq!(b.start, NOW_SECS, "the first admission's start stands");
    let stages = validate_stages(&path);
    assert_eq!(stages.len(), 1);
    assert_eq!(stages[0].run_dir.as_deref(), Some(given));
    assert_eq!(stages[0].end, None);
    // A directory named without the prefix is still the run's identity.
    let c = admitted(run(&path, &admit(ROUND, Some("/w/tmp/elsewhere"))).unwrap());
    assert!(c.admitted_now);
    assert_eq!(c.run_id, "elsewhere");
    assert_eq!(validate_stages(&path).len(), 2);
}

#[test]
fn accept_result_closes_the_round_stage_once_with_its_outcome() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    assert_eq!(
        run(&path, &accept("nope", None, StageOutcome::Pass, None))
            .unwrap_err()
            .key(),
        "round-unknown"
    );
    let applied = apply(
        &path,
        &accept(ROUND, None, StageOutcome::Pass, None),
        &env(),
        LOCK,
    )
    .unwrap();
    let Report::AcceptResult(a) = applied.report else {
        panic!("{:?}", applied.report)
    };
    assert!(a.closed_now);
    assert_eq!((a.start, a.end), (ROUND_START, NOW_SECS));
    assert_eq!(a.run_dir, None);
    assert_eq!(a.outcome, Some(StageOutcome::Pass));
    let doc = object(&path);
    assert_eq!(
        keys(doc["stages"][0].as_object().unwrap()),
        ["kind", "round_id", "start", "end", "outcome"]
    );
    assert_eq!(doc["stages"][0]["outcome"], "pass");
    // The repeat is a no-op: the recorded end and word, whatever it asks.
    let again = run_at(
        &path,
        &accept(ROUND, None, StageOutcome::Fail, None),
        NOW_SECS + 60,
    )
    .unwrap();
    let Report::AcceptResult(b) = again.report else {
        panic!("{:?}", again.report)
    };
    assert!(!b.closed_now);
    assert_eq!(b.end, NOW_SECS);
    assert_eq!(b.outcome, Some(StageOutcome::Pass));
    assert_eq!(object(&path)["stages"][0]["outcome"], "pass");
    // A superseded round's result is history, not the current round's.
    let path = item_file(dir.path());
    run(&path, &begin(RoundKind::Dev)).unwrap();
    let err = run(&path, &accept(ROUND, None, StageOutcome::Pass, None)).unwrap_err();
    assert_eq!(err.key(), "round-superseded");
    // A stage a legacy writer closed carries no word; the reply says so.
    let legacy = dir.path().join("workflow-state-KEN-2.json");
    fs::write(
        &legacy,
        ITEM.replacen("\"end\": null", "\"end\": 1769600900", 1),
    )
    .unwrap();
    let closed = run(&legacy, &accept(ROUND, None, StageOutcome::Pass, None)).unwrap();
    let Report::AcceptResult(c) = closed.report else {
        panic!("{:?}", closed.report)
    };
    assert!(!c.closed_now);
    assert_eq!(c.end, 1_769_600_900);
    assert_eq!(c.outcome, None);
}

/// Decision 80: a run that ended without a pass closes its admitted stage
/// with the word, so no admitted run stays open after it ended, and the
/// closed stage keeps its cost: its start, its end and the `validate_rounds`
/// row beside it.
#[test]
fn a_non_pass_outcome_closes_the_admitted_run_and_keeps_its_cost() {
    let dir = tempfile::tempdir().unwrap();
    let rows = [
        (StageOutcome::Fail, "fail"),
        (StageOutcome::NoVerdict, "no-verdict"),
        (StageOutcome::Lost, "lost"),
        (StageOutcome::Stopped, "stopped"),
    ];
    for (outcome, word) in rows {
        let path = item_file(dir.path());
        let a = admitted(apply(&path, &admit(ROUND, None), &env(), LOCK).unwrap());
        // The cost row dev-artifact-check writes for the round's receipt.
        let mut doc = object(&path);
        doc.insert(
            "validate_rounds".into(),
            json!([{"round_id": ROUND, "kind": "implement", "mode": "full", "seconds": 90}]),
        );
        fs::write(&path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
        let cost = doc["validate_rounds"].clone();

        let closed = apply(
            &path,
            &accept(ROUND, Some(&a.run_dir), outcome, None),
            &at(NOW_SECS + 90),
            LOCK,
        )
        .unwrap();
        let Report::AcceptResult(r) = closed.report else {
            panic!("{:?}", closed.report)
        };
        assert!(r.closed_now, "{word}");
        assert_eq!(r.kind, StageKind::Validate, "{word}");
        assert_eq!(r.outcome, Some(outcome), "{word}");
        assert_eq!((r.start, r.end), (NOW_SECS, NOW_SECS + 90), "{word}");
        let after = object(&path);
        let stage = after["stages"][1].as_object().unwrap();
        assert_eq!(
            keys(stage),
            ["kind", "round_id", "start", "end", "run_dir", "outcome"],
            "{word}"
        );
        assert_eq!(stage["outcome"], word);
        assert_eq!(stage["start"], NOW_SECS);
        assert_eq!(stage["end"], NOW_SECS + 90);
        assert_eq!(stage["run_dir"], a.run_dir);
        assert_eq!(
            after["validate_rounds"], cost,
            "{word}: the cost row stands"
        );
        assert_eq!(
            after["stages"][0]["end"],
            Value::Null,
            "{word}: the round's own stage stays open"
        );
        let stages = validate_stages(&path);
        assert_eq!(stages.len(), 1, "{word}");
        assert_eq!(stages[0].outcome, Some(outcome), "{word}");
        // A later pass on the closed run changes nothing: the first word
        // stands and the reply carries it.
        let again = run_at(
            &path,
            &accept(ROUND, Some(&a.run_dir), StageOutcome::Pass, None),
            NOW_SECS + 120,
        )
        .unwrap();
        let Report::AcceptResult(b) = again.report else {
            panic!("{:?}", again.report)
        };
        assert!(!b.closed_now, "{word}");
        assert_eq!(b.outcome, Some(outcome), "{word}");
        assert_eq!(b.end, NOW_SECS + 90, "{word}");
        assert_eq!(object(&path)["stages"][1]["outcome"], word);
        // Another run of the round is not this one.
        let err = run(
            &path,
            &accept(
                ROUND,
                Some("/w/tmp/dev-validate-9"),
                StageOutcome::Pass,
                None,
            ),
        )
        .unwrap_err();
        assert!(matches!(err, Error::RunUnknown { .. }), "{word}: {err}");
    }
}

/// Decisions 81 and 103: the runtime stats the artifact the acceptance
/// rests on, and its modification time is the stage's end when it lies in
/// `[start, now]`; one outside is refused with the bounds, an artifact that
/// cannot be stat'ed is refused by name, and the file keeps its bytes.
#[test]
fn accept_result_end_is_read_from_the_artifact_and_bounded_to_the_stage_and_the_clock() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let text = fs::read_to_string(&path).unwrap();
    for (name, mtime) in [
        ("before-start", ROUND_START - 1),
        ("after-now", NOW_SECS + 1),
        ("epoch", 0),
    ] {
        let file = artifact(dir.path(), name, mtime);
        let err = apply(
            &path,
            &accept(ROUND, None, StageOutcome::Pass, Some(&file)),
            &env(),
            LOCK,
        )
        .unwrap_err();
        assert_eq!(err.key(), "end-out-of-range", "{name}");
        assert_eq!(
            err.fields(),
            vec![
                ("round_id".to_owned(), ROUND.to_owned()),
                ("end".to_owned(), mtime.to_string()),
                ("start".to_owned(), ROUND_START.to_string()),
                ("now".to_owned(), NOW_SECS.to_string()),
            ],
            "{name}"
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), text, "{name}");
    }
    // An artifact the runtime cannot stat is a refusal, never an end of now.
    let missing = dir.path().join("review-nobody-1.json");
    let err = apply(
        &path,
        &accept(ROUND, None, StageOutcome::Pass, Some(&missing)),
        &env(),
        LOCK,
    )
    .unwrap_err();
    assert_eq!(err.key(), "end-artifact-unreadable");
    assert_eq!(
        err.fields(),
        vec![("path".to_owned(), missing.display().to_string())]
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), text);
    // Both bounds are in range; the first close wins.
    for (mtime, label) in [(ROUND_START, "start"), (NOW_SECS, "now")] {
        let path = item_file(dir.path());
        let file = artifact(dir.path(), label, mtime);
        let applied = apply(
            &path,
            &accept(ROUND, None, StageOutcome::Pass, Some(&file)),
            &env(),
            LOCK,
        )
        .unwrap();
        let Report::AcceptResult(a) = applied.report else {
            panic!("{:?}", applied.report)
        };
        assert!(a.closed_now, "{label}");
        assert_eq!(a.end, mtime, "{label}");
        assert_eq!(object(&path)["stages"][0]["end"], mtime, "{label}");
    }
    // The review workflow's case: the review stage ends at the last
    // accepted artifact's time, not at the accept.
    let path = item_file(dir.path());
    let begun = run(&path, &begin(RoundKind::Review)).unwrap();
    let Report::BeginRound(review) = begun.report else {
        panic!("{:?}", begun.report)
    };
    let mtime = NOW_SECS + 300;
    let accepted = artifact(dir.path(), "review-a-1.json", mtime);
    let applied = apply(
        &path,
        &accept(&review.round_id, None, StageOutcome::Pass, Some(&accepted)),
        &at(NOW_SECS + 400),
        LOCK,
    )
    .unwrap();
    let Report::AcceptResult(a) = applied.report else {
        panic!("{:?}", applied.report)
    };
    assert_eq!(a.kind, StageKind::Review);
    assert_eq!(a.end, mtime);
    let newer = artifact(dir.path(), "review-b-1.json", mtime + 5);
    let later = run_at(
        &path,
        &accept(&review.round_id, None, StageOutcome::Pass, Some(&newer)),
        NOW_SECS + 500,
    )
    .unwrap();
    let Report::AcceptResult(b) = later.report else {
        panic!("{:?}", later.report)
    };
    assert!(!b.closed_now);
    assert_eq!(b.end, mtime, "the first end stands");
    // A no-op repeat is still held to the bounds: a stale request is a
    // request error, whatever the stage holds.
    let stale = artifact(dir.path(), "review-stale.json", 1);
    let err = run_at(
        &path,
        &accept(&review.round_id, None, StageOutcome::Pass, Some(&stale)),
        NOW_SECS + 500,
    )
    .unwrap_err();
    assert_eq!(err.key(), "end-out-of-range");
}

/// A child the test holds, so a planted pid names a process it owns; the
/// test reaps it at the end.
struct Owned(Child);

impl Owned {
    fn sleep() -> Owned {
        Owned(Command::new("sleep").arg("30").spawn().expect("sleep"))
    }
    fn pid(&self) -> u32 {
        self.0.id()
    }
    /// End the process without reaping it: the pid stays this child's, as
    /// a zombie, until the drop reaps it.
    fn end(&mut self) {
        self.0.kill().expect("kill");
        // The kernel turns the process into a zombie once the signal
        // lands; wait on that state, read as the runtime reads it, without
        // reaping it.
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while matches!(
            agent_runtime::process::identity(self.pid()),
            agent_runtime::reading::Reading::Live(_)
        ) {
            assert!(
                std::time::Instant::now() < deadline,
                "the child did not end"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// A run directory as `dev-validate-run` leaves it: its `start` record and
/// the files the row plants.
fn run_dir(path: &str, files: &[(&str, String)]) -> PathBuf {
    let dir = PathBuf::from(path);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("start"), format!("start={NOW_SECS}\nhead=abc\n")).unwrap();
    for (name, text) in files {
        fs::write(dir.join(name), text).unwrap();
    }
    dir
}

fn state_of(report: &Report, run_dir: &str) -> RunState {
    let Report::ReconcileRound(r) = report else {
        panic!("{report:?}")
    };
    r.runs
        .iter()
        .find(|run| run.run_dir == run_dir)
        .unwrap_or_else(|| panic!("no row for {run_dir} in {:?}", r.runs))
        .state
        .clone()
}

fn closed(outcome: StageOutcome, cause: RunCause, seconds: Option<u64>) -> RunState {
    RunState::Closed {
        outcome,
        cause,
        seconds,
    }
}

/// Decision 102: the reconcile closes every admitted run that will not
/// end on its own, with the word the host supports, keeps a live run open
/// and reports what it could not read, and touches no cost.
#[test]
fn reconcile_round_closes_every_ended_or_lost_run_and_keeps_a_live_one_open() {
    let dir = tempfile::tempdir().unwrap();
    let worktree = dir.path().join("wt");
    fs::create_dir_all(worktree.join("tmp")).unwrap();
    let path = dir.path().join("workflow-state-KEN-4687.json");
    fs::write(
        &path,
        ITEM.replacen(
            &format!("\"worktree\": \"{WORKTREE}\""),
            &format!("\"worktree\": \"{}\"", worktree.display()),
            1,
        ),
    )
    .unwrap();
    assert_eq!(
        run(&path, &reconcile("no-such-round")).unwrap_err().key(),
        "round-unknown"
    );
    // Nine attempts of the round, each admitted at its own second.
    let mut runs = Vec::new();
    for i in 0..9 {
        let request = if i == 0 {
            admit(ROUND, None)
        } else {
            admit_next(ROUND)
        };
        runs.push(admitted(run_at(&path, &request, NOW_SECS + i).unwrap()).run_dir);
    }
    let [
        live,
        refused,
        gone,
        failing,
        bounded,
        passing,
        unlaunched,
        garbled,
        skewed,
    ] = <[String; 9]>::try_from(runs).unwrap();
    let mut live_child = Owned::sleep();
    run_dir(&live, &[("pid", format!("{}\n", live_child.pid()))]);
    // `refused`: the start was refused; the directory never came to be.
    let mut gone_child = Owned::sleep();
    run_dir(&gone, &[("pid", format!("{}\n", gone_child.pid()))]);
    gone_child.end();
    let iso = |secs: u64| at(secs).iso();
    run_dir(
        &failing,
        &[
            ("pid", "1\n".to_owned()),
            ("exit", format!("guard-exit=1 at={}\n", iso(NOW_SECS + 60))),
            (
                "timing",
                format!(
                    "started-at={}\nended-at={}\nseconds=55\n",
                    iso(NOW_SECS + 5),
                    iso(NOW_SECS + 60)
                ),
            ),
        ],
    );
    run_dir(
        &bounded,
        &[(
            "exit",
            format!(
                "guard-exit=3 at={} verdict=no-verdict cause=host\n",
                iso(NOW_SECS + 70)
            ),
        )],
    );
    run_dir(
        &passing,
        &[("exit", format!("guard-exit=0 at={}\n", iso(NOW_SECS + 80)))],
    );
    run_dir(&unlaunched, &[]);
    run_dir(&garbled, &[("exit", "not a sentinel\n".to_owned())]);
    // A sentinel time before the stage started: a clock the runner and this
    // host disagree on yields to the reconcile's.
    run_dir(
        &skewed,
        &[("exit", format!("guard-exit=1 at={}\n", iso(ROUND_START)))],
    );
    // The cost row dev-artifact-check writes for the round's receipt.
    let mut doc = object(&path);
    doc.insert(
        "validate_rounds".into(),
        json!([{"round_id": ROUND, "kind": "implement", "mode": "full", "seconds": 55}]),
    );
    fs::write(&path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    let cost = doc["validate_rounds"].clone();

    let applied = apply(&path, &reconcile(ROUND), &at(NOW_SECS + 100), LOCK).unwrap();
    let report = &applied.report;
    assert_eq!(
        state_of(report, &live),
        RunState::Live {
            pid: live_child.pid()
        }
    );
    assert_eq!(
        state_of(report, &refused),
        closed(StageOutcome::Stopped, RunCause::RunDirAbsent, None)
    );
    assert_eq!(
        state_of(report, &gone),
        closed(StageOutcome::Lost, RunCause::ProcessGone, None)
    );
    assert_eq!(
        state_of(report, &failing),
        closed(StageOutcome::Fail, RunCause::Sentinel, Some(55))
    );
    assert_eq!(
        state_of(report, &bounded),
        closed(StageOutcome::NoVerdict, RunCause::Sentinel, None)
    );
    assert_eq!(
        state_of(report, &passing),
        closed(StageOutcome::Pass, RunCause::Sentinel, None)
    );
    assert_eq!(
        state_of(report, &unlaunched),
        closed(StageOutcome::Lost, RunCause::PidUnrecorded, None)
    );
    assert!(
        matches!(state_of(report, &garbled), RunState::Unreadable { .. }),
        "{report:?}"
    );
    assert_eq!(
        state_of(report, &skewed),
        closed(StageOutcome::Fail, RunCause::Sentinel, None)
    );
    let after = object(&path);
    assert_eq!(after["validate_rounds"], cost, "the cost row stands");
    assert_eq!(
        after["stages"][0]["end"],
        Value::Null,
        "the round's own stage is the acceptance owner's to close"
    );
    let stages = validate_stages(&path);
    let stage = |dir: &str| {
        stages
            .iter()
            .find(|s| s.run_dir.as_deref() == Some(dir))
            .unwrap()
    };
    assert_eq!((stage(&live).end, stage(&live).outcome), (None, None));
    assert_eq!((stage(&garbled).end, stage(&garbled).outcome), (None, None));
    let expected = [
        (&refused, StageOutcome::Stopped, NOW_SECS + 100),
        (&gone, StageOutcome::Lost, NOW_SECS + 100),
        (&failing, StageOutcome::Fail, NOW_SECS + 60),
        (&bounded, StageOutcome::NoVerdict, NOW_SECS + 70),
        (&passing, StageOutcome::Pass, NOW_SECS + 80),
        (&unlaunched, StageOutcome::Lost, NOW_SECS + 100),
        (&skewed, StageOutcome::Fail, NOW_SECS + 100),
    ];
    for (dir, outcome, end) in expected {
        let s = stage(dir);
        assert_eq!((s.outcome, s.end), (Some(outcome), Some(end)), "{dir}");
        assert!(
            s.start <= NOW_SECS + 8,
            "{dir}: the admission's start stands"
        );
    }
    for row in after["stages"].as_array().unwrap().iter().skip(1) {
        let row = row.as_object().unwrap();
        let open = row["end"].is_null();
        let expected: &[&str] = if open {
            &["kind", "round_id", "start", "end", "run_dir"]
        } else {
            &["kind", "round_id", "start", "end", "run_dir", "outcome"]
        };
        assert_eq!(keys(row), expected, "{}", row["run_dir"]);
    }

    // A repeat reads only what stands open: the live and the unreadable
    // run; the closed runs keep their words and are not rows.
    let again = run_at(&path, &reconcile(ROUND), NOW_SECS + 200).unwrap();
    let Report::ReconcileRound(r) = &again.report else {
        panic!("{:?}", again.report)
    };
    let mut open: Vec<&str> = r.runs.iter().map(|run| run.run_dir.as_str()).collect();
    open.sort_unstable();
    let mut expected = [live.as_str(), garbled.as_str()];
    expected.sort_unstable();
    assert_eq!(open, expected);
    assert_eq!(stage(&failing).end, Some(NOW_SECS + 60));
    assert_eq!(validate_stages(&path), stages, "the repeat wrote nothing");

    // The live run's child ends without its sentinel: lost, at the read.
    live_child.end();
    let ended = run_at(&path, &reconcile(ROUND), NOW_SECS + 300).unwrap();
    assert_eq!(
        state_of(&ended.report, &live),
        closed(StageOutcome::Lost, RunCause::ProcessGone, None)
    );
    let s = validate_stages(&path)
        .into_iter()
        .find(|s| s.run_dir.as_deref() == Some(live.as_str()))
        .unwrap();
    assert_eq!(
        (s.outcome, s.end),
        (Some(StageOutcome::Lost), Some(NOW_SECS + 300))
    );
    // A round with nothing open reconciles to no rows.
    let path = item_file(dir.path());
    let none = run(&path, &reconcile(ROUND)).unwrap();
    let Report::ReconcileRound(r) = &none.report else {
        panic!("{:?}", none.report)
    };
    assert!(r.runs.is_empty());
}

/// Decision 52: `.verification` is `{head, verdict, reason, source, at}`,
/// appended on the first write and replaced in place by a later one; a
/// word that is no verdict, ci-wait's `pending` among them, writes
/// nothing.
#[test]
fn record_verification_writes_the_record_once_and_a_later_write_replaces_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let before = object(&path);
    let verify = |round: Option<&str>, head: &str, verdict: &str| {
        Request::RecordVerification(RecordVerification {
            round_id: round.map(str::to_owned),
            head: head.into(),
            verdict: verdict.into(),
            reason: format!(
                "no CI configured: no active workflows and no required checks on main ({verdict})"
            ),
            source: "ci-wait --required-only".into(),
        })
    };
    let first = apply(
        &path,
        &verify(None, "a".repeat(40).as_str(), "none"),
        &env(),
        LOCK,
    )
    .unwrap();
    let Report::RecordVerification(a) = first.report else {
        panic!("{:?}", first.report)
    };
    assert!(!a.replaced);
    assert_eq!(a.verdict, "none");
    assert_eq!(a.at, env().iso());
    let after = object(&path);
    let mut expected_keys = keys(&before);
    expected_keys.push("verification".to_owned());
    assert_eq!(keys(&after), expected_keys, "the record is appended once");
    for (key, value) in &before {
        assert_eq!(&after[key], value, "{key}");
    }
    let record = after["verification"].as_object().unwrap();
    assert_eq!(keys(record), ["head", "verdict", "reason", "source", "at"]);
    assert_eq!(record["head"], "a".repeat(40));
    assert_eq!(record["verdict"], "none");
    assert_eq!(record["source"], "ci-wait --required-only");
    assert_eq!(record["at"], env().iso());

    // A later head's verdict replaces the record where it stands.
    let later = at(NOW_SECS + 90);
    let second = apply(
        &path,
        &verify(None, "b".repeat(40).as_str(), "pass"),
        &later,
        LOCK,
    )
    .unwrap();
    let Report::RecordVerification(b) = second.report else {
        panic!("{:?}", second.report)
    };
    assert!(b.replaced);
    assert_eq!(b.at, later.iso());
    let again = object(&path);
    assert_eq!(keys(&again), keys(&after), "one record, in its place");
    assert_eq!(again["verification"]["head"], "b".repeat(40));
    assert_eq!(again["verification"]["verdict"], "pass");
    assert_eq!(again["verification"]["at"], later.iso());

    // A word that is no verdict is refused and writes nothing: ci-wait's
    // `pending` names a wait that ended without a result.
    let text = fs::read_to_string(&path).unwrap();
    for word in ["pending", "green", "PASS", ""] {
        let err = run(&path, &verify(None, "c".repeat(40).as_str(), word)).unwrap_err();
        assert_eq!(err.key(), "verdict-invalid", "{word:?}");
        assert_eq!(
            err.fields(),
            vec![("verdict".to_owned(), word.to_owned())],
            "{word:?}"
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), text, "{word:?}");
    }
    // A round named must be one the item ran.
    let err = run(
        &path,
        &verify(Some("no-such-round"), "d".repeat(40).as_str(), "fail"),
    )
    .unwrap_err();
    assert_eq!(err.key(), "round-unknown");
    assert_eq!(fs::read_to_string(&path).unwrap(), text);
    let bound = run(&path, &verify(Some(ROUND), "d".repeat(40).as_str(), "fail")).unwrap();
    let Report::RecordVerification(c) = bound.report else {
        panic!("{:?}", bound.report)
    };
    assert!(c.replaced);
    assert_eq!(object(&path)["verification"]["verdict"], "fail");
}

/// Step-4 map § A10 and decision 100: a handoff names the round it leaves
/// open; the same content recorded again is the same operation and writes
/// nothing, other content needs `supersede` and keeps the resume stamp;
/// the continuing session resumes that same round, stamped once, and reads
/// the admitted run it waits on instead of starting a new one.
#[test]
fn a_handoff_is_recorded_once_per_content_and_resumed_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let text = fs::read_to_string(&path).unwrap();
    // No record stands: nothing to resume, nothing written.
    let err = run(&path, &resume()).unwrap_err();
    assert_eq!(err.key(), "handoff-none");
    assert_eq!(fs::read_to_string(&path).unwrap(), text);
    // The round named must be one the item ran.
    let err = run(&path, &handoff(Some("no-such-round"), None, None)).unwrap_err();
    assert_eq!(err.key(), "round-unknown");
    assert_eq!(fs::read_to_string(&path).unwrap(), text);
    // The legacy stamp rule on written_at.
    for (given, key) in [
        ("2026-01-29 15:20:00Z", "handoff-written-at-invalid"),
        ("soon", "handoff-written-at-invalid"),
        ("2026-01-29T15:20:01Z", "handoff-written-at-future"),
    ] {
        let err = apply(
            &path,
            &handoff(Some(ROUND), None, Some(given)),
            &env(),
            LOCK,
        )
        .unwrap_err();
        assert_eq!(err.key(), key, "{given}");
        assert_eq!(err.fields()[0], ("written_at".to_owned(), given.to_owned()));
        assert_eq!(fs::read_to_string(&path).unwrap(), text, "{given}");
    }

    let a = admitted(apply(&path, &admit(ROUND, None), &env(), LOCK).unwrap());
    let before = object(&path);
    // A past written_at is kept on the first write.
    let past = "2026-01-29T15:00:00Z";
    let written = apply(
        &path,
        &handoff(Some(ROUND), Some(Relaunch::Fresh), Some(past)),
        &at(NOW_SECS + 10),
        LOCK,
    )
    .unwrap();
    let Report::RecordHandoff(h) = written.report else {
        panic!("{:?}", written.report)
    };
    assert!(!h.replaced);
    assert!(h.recorded_now);
    assert_eq!(h.round_id.as_deref(), Some(ROUND));
    assert_eq!(h.written_at, past);
    let after = object(&path);
    let mut expected_keys = keys(&before);
    expected_keys.push("handoff".to_owned());
    assert_eq!(keys(&after), expected_keys, "the record is appended once");
    let record = after["handoff"].as_object().unwrap();
    assert_eq!(
        keys(record),
        [
            "round_id",
            "merged",
            "remaining",
            "branch",
            "worktree",
            "open_pr",
            "traps",
            "context",
            "relaunch",
            "written_at",
        ]
    );
    assert_eq!(record["round_id"], ROUND);
    assert_eq!(record["relaunch"], "fresh");
    assert_eq!(record["written_at"], past);
    assert_eq!(record["merged"], json!(["#2714"]));
    assert_eq!(record["context"]["decision"], "handoff");
    assert!(
        record.get("resumed_at").is_none(),
        "a standing record carries no resumed_at, as the legacy judge reads one"
    );
    // The same content again, later and without a stamp, is the same
    // operation: nothing written, the standing stamp reported.
    let repeat = run_at(
        &path,
        &handoff(Some(ROUND), Some(Relaunch::Fresh), None),
        NOW_SECS + 20,
    )
    .unwrap();
    let Report::RecordHandoff(k) = repeat.report else {
        panic!("{:?}", repeat.report)
    };
    assert!(!k.replaced);
    assert!(!k.recorded_now);
    assert_eq!(k.written_at, past);
    assert_eq!(object(&path)["handoff"], after["handoff"]);

    // The resume stamps the record and names what continues: the round,
    // its relaunch route, the remaining steps and the admitted open run.
    let resumed = apply(&path, &resume(), &at(NOW_SECS + 600), LOCK).unwrap();
    let Report::ResumeHandoff(r) = resumed.report else {
        panic!("{:?}", resumed.report)
    };
    assert!(r.resumed_now);
    assert_eq!(r.resumed_at, NOW_SECS + 600);
    assert_eq!(r.round_id.as_deref(), Some(ROUND));
    assert_eq!(r.relaunch, Some(Relaunch::Fresh));
    assert_eq!(r.remaining, vec!["merge-pr § 5 step 3".to_owned()]);
    assert_eq!(r.open_runs, vec![a.run_dir.clone()]);
    let record = object(&path)["handoff"].as_object().unwrap().clone();
    assert_eq!(record["resumed_at"], NOW_SECS + 600);
    assert_eq!(record["written_at"], past);
    assert_eq!(
        item(&path).stages.len(),
        2,
        "a resume opens no round and admits no run"
    );
    // The second resume is a no-op reporting the first stamp.
    let again = run_at(&path, &resume(), NOW_SECS + 900).unwrap();
    let Report::ResumeHandoff(r2) = again.report else {
        panic!("{:?}", again.report)
    };
    assert!(!r2.resumed_now);
    assert_eq!(r2.resumed_at, NOW_SECS + 600);
    assert_eq!(object(&path)["handoff"]["resumed_at"], NOW_SECS + 600);
    // A replay of the record after the resume consumes nothing: the
    // consumed handoff stays consumed.
    let replay = run_at(
        &path,
        &handoff(Some(ROUND), Some(Relaunch::Fresh), None),
        NOW_SECS + 910,
    )
    .unwrap();
    let Report::RecordHandoff(k) = replay.report else {
        panic!("{:?}", replay.report)
    };
    assert!(!k.recorded_now);
    assert_eq!(object(&path)["handoff"], Value::Object(record.clone()));
    // Other content over a standing record refuses, naming the fields, and
    // writes nothing.
    let other = |supersede| {
        handoff_with(
            Some(ROUND),
            Some(Relaunch::Fresh),
            None,
            "merge-pr § 5 step 4",
            supersede,
        )
    };
    let err = run_at(&path, &other(false), NOW_SECS + 920).unwrap_err();
    assert_eq!(err.key(), "handoff-differs");
    assert_eq!(
        err.fields(),
        vec![
            ("path".to_owned(), path.display().to_string()),
            ("fields".to_owned(), "remaining".to_owned()),
        ]
    );
    assert_eq!(object(&path)["handoff"], Value::Object(record.clone()));
    // Asked to supersede, the write replaces the content, stamps anew and
    // keeps the resume stamp.
    let superseded = apply(&path, &other(true), &at(NOW_SECS + 930), LOCK).unwrap();
    let Report::RecordHandoff(s) = superseded.report else {
        panic!("{:?}", superseded.report)
    };
    assert!(s.replaced);
    assert!(s.recorded_now);
    assert_eq!(s.written_at, at(NOW_SECS + 930).iso());
    let record = object(&path)["handoff"].as_object().unwrap().clone();
    assert_eq!(record["remaining"], json!(["merge-pr § 5 step 4"]));
    assert_eq!(record["written_at"], at(NOW_SECS + 930).iso());
    assert_eq!(record["resumed_at"], NOW_SECS + 600);
    assert_eq!(
        keys(&record)[9..],
        ["written_at".to_owned(), "resumed_at".to_owned()]
    );
    // Once the run closed, a resume names no open run.
    run(
        &path,
        &accept(ROUND, Some(&a.run_dir), StageOutcome::Lost, None),
    )
    .unwrap();
    let after_close = run(&path, &resume()).unwrap();
    let Report::ResumeHandoff(r3) = after_close.report else {
        panic!("{:?}", after_close.report)
    };
    assert_eq!(r3.open_runs, Vec::<String>::new());

    // A record the legacy `set handoff` wrote names no round and no route
    // and carries `resumed_at: null`; the resume still stamps it, and a
    // supersede of an unresumed one carries no stamp over.
    let legacy = dir.path().join("workflow-state-KEN-3.json");
    let mut doc: Document = serde_json::from_str(ITEM).unwrap();
    doc.insert(
        "handoff".into(),
        json!({
            "merged": [], "remaining": ["submit-pr § 2"], "branch": "b", "worktree": "/w",
            "open_pr": null, "traps": [], "context": null, "written_at": "2026-01-29T15:00:00Z",
            "resumed_at": null
        }),
    );
    fs::write(&legacy, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    let superseded = run(&legacy, &other(true)).unwrap();
    let Report::RecordHandoff(s) = superseded.report else {
        panic!("{:?}", superseded.report)
    };
    assert!(s.replaced);
    assert!(
        object(&legacy)["handoff"].get("resumed_at").is_none(),
        "an unresumed record superseded stays unresumed"
    );
    fs::write(&legacy, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    let resumed = run(&legacy, &resume()).unwrap();
    let Report::ResumeHandoff(l) = resumed.report else {
        panic!("{:?}", resumed.report)
    };
    assert!(l.resumed_now);
    assert_eq!(l.round_id, None);
    assert_eq!(l.relaunch, None);
    assert_eq!(l.remaining, vec!["submit-pr § 2".to_owned()]);
    assert_eq!(l.open_runs, Vec::<String>::new());
    assert_eq!(object(&legacy)["handoff"]["resumed_at"], NOW_SECS);
}

// --- the binary: the wire names a workflow writes ------------------------

fn op(path: &Path, request: &Path) -> Output {
    support::isolated()
        .args(["op", "--file"])
        .arg(path)
        .arg("--request")
        .arg(request)
        .output()
        .unwrap()
}

fn reply(out: &Output) -> Value {
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "no reply: {e}\nstdout={}\nstderr={}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        )
    })
}

fn first_stderr_line(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr)
        .lines()
        .next()
        .unwrap_or_default()
        .to_owned()
}

fn write(dir: &Path, name: &str, text: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, text).unwrap();
    path
}

/// The workflows write these requests as JSON files: the `op` words, the
/// `attempt`, `outcome`, `end` and `supersede` fields and the reply's
/// `run_id`, `run_dir`, `outcome` and `state` names are the contract they
/// read.
#[test]
fn op_admits_closes_reconciles_and_hands_off_a_round_through_the_wire_names() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-KEN-4687.json", ITEM);
    let admit = write(
        dir.path(),
        "admit.json",
        &format!(r#"{{"op": "record-validation-admission", "round_id": "{ROUND}"}}"#),
    );
    let out = op(&path, &admit);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["op"], "record-validation-admission");
    assert_eq!(report["minted"], true);
    assert_eq!(report["admitted_now"], true);
    let run_id = report["run_id"].as_str().unwrap().to_owned();
    let run_dir = report["run_dir"].as_str().unwrap().to_owned();
    assert_eq!(run_dir, format!("{WORKTREE}/tmp/dev-validate-{run_id}"));
    // The same request file again is the same admission.
    let out = op(&path, &admit);
    assert!(out.status.success());
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["admitted_now"], false);
    assert_eq!(report["run_dir"], run_dir);

    // A stale end artifact is refused on the keyed line with the bounds.
    let stale_artifact = artifact(dir.path(), "review-stale.json", 1);
    let stale = write(
        dir.path(),
        "stale.json",
        &format!(
            r#"{{"op": "accept-result", "round_id": "{ROUND}", "run_dir": "{run_dir}", "outcome": "fail", "end": {{"from_artifact": "{}"}}}}"#,
            stale_artifact.display()
        ),
    );
    let out = op(&path, &stale);
    assert_eq!(out.status.code(), Some(1));
    let line = first_stderr_line(&out);
    assert!(
        line.starts_with(&format!(
            "orch-runtime: end-out-of-range round_id={ROUND} end=1 start="
        )),
        "{line}"
    );
    assert_eq!(reply(&out)["refusal"]["key"], "end-out-of-range");
    // A word that is no outcome is not a request, and neither is a close
    // without one: no word is assumed.
    for (name, text) in [
        (
            "green.json",
            format!(r#"{{"op": "accept-result", "round_id": "{ROUND}", "outcome": "green"}}"#),
        ),
        (
            "wordless.json",
            format!(r#"{{"op": "accept-result", "round_id": "{ROUND}"}}"#),
        ),
    ] {
        let request = write(dir.path(), name, &text);
        let out = op(&path, &request);
        assert_eq!(out.status.code(), Some(1), "{name}");
        assert_eq!(reply(&out)["refusal"]["key"], "request-invalid", "{name}");
        let state: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(state["stages"][0]["end"], Value::Null, "{name}");
    }

    let close = write(
        dir.path(),
        "close.json",
        &format!(
            r#"{{"op": "accept-result", "round_id": "{ROUND}", "run_dir": "{run_dir}", "outcome": "no-verdict"}}"#
        ),
    );
    let out = op(&path, &close);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["op"], "accept-result");
    assert_eq!(report["kind"], "validate");
    assert_eq!(report["outcome"], "no-verdict");
    assert_eq!(report["closed_now"], true);
    let state: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(state["stages"][1]["outcome"], "no-verdict");
    assert_eq!(state["stages"][1]["run_dir"], run_dir);

    // The next attempt by name, then the reconcile: its directory was never
    // created, so it closes stopped.
    let next = write(
        dir.path(),
        "next.json",
        &format!(
            r#"{{"op": "record-validation-admission", "round_id": "{ROUND}", "attempt": "next"}}"#
        ),
    );
    let out = op(&path, &next);
    assert!(out.status.success(), "{}", first_stderr_line(&out));
    let next_dir = reply(&out)["result"]["report"]["run_dir"].clone();
    assert_ne!(next_dir, run_dir);
    let reconcile = write(
        dir.path(),
        "reconcile.json",
        &format!(r#"{{"op": "reconcile-round", "round_id": "{ROUND}"}}"#),
    );
    let out = op(&path, &reconcile);
    assert!(out.status.success(), "{}", first_stderr_line(&out));
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["op"], "reconcile-round");
    assert_eq!(
        report["runs"],
        json!([{
            "run_dir": next_dir,
            "state": "closed",
            "outcome": "stopped",
            "cause": "run-dir-absent",
        }])
    );
    let state: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(state["stages"][2]["outcome"], "stopped");

    let record = write(
        dir.path(),
        "handoff.json",
        &format!(
            r#"{{"op": "record-handoff", "round_id": "{ROUND}", "merged": [], "remaining": ["dev-start § 3"], "branch": "b", "worktree": "/w", "open_pr": null, "traps": [], "context": null, "relaunch": "fresh"}}"#
        ),
    );
    let out = op(&path, &record);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["op"], "record-handoff");
    assert_eq!(report["replaced"], false);
    assert_eq!(report["recorded_now"], true);
    assert!(report["written_at"].as_str().unwrap().ends_with('Z'));
    let out = op(&path, &record);
    assert!(out.status.success());
    assert_eq!(reply(&out)["result"]["report"]["recorded_now"], false);
    let other = write(
        dir.path(),
        "handoff-other.json",
        &format!(
            r#"{{"op": "record-handoff", "round_id": "{ROUND}", "merged": [], "remaining": ["dev-start § 4"], "branch": "b", "worktree": "/w", "open_pr": null, "traps": [], "context": null, "relaunch": "fresh"}}"#
        ),
    );
    let out = op(&path, &other);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(reply(&out)["refusal"]["key"], "handoff-differs");
    let superseding = write(
        dir.path(),
        "handoff-supersede.json",
        &format!(
            r#"{{"op": "record-handoff", "supersede": true, "round_id": "{ROUND}", "merged": [], "remaining": ["dev-start § 4"], "branch": "b", "worktree": "/w", "open_pr": null, "traps": [], "context": null, "relaunch": "fresh"}}"#
        ),
    );
    let out = op(&path, &superseding);
    assert!(out.status.success(), "{}", first_stderr_line(&out));
    assert_eq!(reply(&out)["result"]["report"]["replaced"], true);
    let resume = write(dir.path(), "resume.json", r#"{"op": "resume-handoff"}"#);
    let out = op(&path, &resume);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["op"], "resume-handoff");
    assert_eq!(report["round_id"], ROUND);
    assert_eq!(report["relaunch"], "fresh");
    assert_eq!(report["resumed_now"], true);
    assert_eq!(report["open_runs"], json!([]));
    assert_eq!(report["remaining"], json!(["dev-start § 4"]));
    let state: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert!(state["handoff"]["resumed_at"].as_u64().is_some());
    let out = op(&path, &resume);
    assert!(out.status.success());
    assert_eq!(reply(&out)["result"]["report"]["resumed_now"], false);
}

/// Decision 124c (10), R-U4g4 Codex probe: the run directory of an admitted
/// validation stage is read three-valued. A directory that cannot be read
/// (its parent refuses traversal) is no proof of absence: the reconcile holds
/// the stage open as unreadable, never closing it `Stopped`; only a
/// directory read `NotFound` closes it.
#[test]
fn an_unreadable_admitted_run_holds_the_stage_open() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let parent = dir.path().join("locked");
    let root = parent.join("run");
    fs::create_dir_all(&root).unwrap();
    let mut child = Owned::sleep();
    fs::write(root.join("pid"), format!("{}\n", child.pid())).unwrap();
    run(&path, &admit(ROUND, Some(root.to_str().unwrap()))).unwrap();
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o000)).unwrap();
    let metadata = fs::metadata(&root).map(|_| ()).map_err(|e| e.kind());
    let result = run(&path, &reconcile(ROUND));
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o700)).unwrap();
    child.end();
    assert_eq!(
        metadata,
        Err(std::io::ErrorKind::PermissionDenied),
        "the fixture made the run directory unreadable"
    );
    let report = result.unwrap();
    assert!(
        validate_stages(&path).iter().all(|s| s.end.is_none()),
        "an unreadable run directory closed the stage: {:?}",
        report.report
    );
    // Removed, the directory reads absent and the stage closes `Stopped`.
    fs::remove_dir_all(&parent).unwrap();
    run(&path, &reconcile(ROUND)).unwrap();
    assert!(
        validate_stages(&path).iter().all(|s| s.end.is_some()),
        "a run directory read absent closes the stage"
    );
}
