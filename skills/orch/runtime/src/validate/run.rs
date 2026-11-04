//! The validation job: the detached process the launcher started for one run.
//! It runs the kept executor, `dev-validate-run --child --run-dir D`, as its
//! bounded child through the one runner, reads the sentinel the child wrote,
//! closes the stage once with the lane's end notice recorded `owed` in the
//! same write, sends the notice through the mailbox program and marks it
//! `sent` or `unsent:<cause>`. A second run of the same job changes nothing:
//! the close is recorded and the notice's mark is what it was. `deliver_owed`
//! is the continuation a crash between the close and the send left behind,
//! run by the item's next `reconcile-round`. `stop` is the job's counterpart:
//! the intentional stop recorded on the stage before the job is ended, so the
//! job's own close and the reconcile's both read the run as `stopped`, never
//! `lost`.
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use agent_runtime::clock;
use agent_runtime::host::{self, Place};
use serde::Serialize;

use super::{KILL_GRACE, apply, item_of_run_dir, load};
use crate::error::{Error, Result};
use crate::mailbox::{Mailbox, Refusal, Sent};
use crate::ops::mail::{KeyedSend, SendResult};
use crate::ops::validate::{self, MarkNotice, RecordEnd, RecordStop, Validate, Validated};
use crate::ops::{self, Env, ReconcileRound, Request, job_ended};
use crate::send::Keyed;
use crate::settings::Settings;
use crate::state::{
    self, FleetState, ItemState, Lane, Locking, Record, Stage, StageKind, StageOutcome, Stop,
    ValidateJob,
};

/// How long the mailbox program is given to take the notice.
const NOTICE_TIMEOUT: Duration = Duration::from_secs(60);
/// How long the launcher's stop is given: the setsid teardown's TERM grace
/// and KILL, or the user manager's own stop of the unit.
const STOP_TIMEOUT: Duration = Duration::from_secs(120);
/// How long the stop waits for the job it ended to read gone: on the setsid
/// route the job outlives its child's group and closes the stage itself
/// (its close and its notice's send), on the unit route the manager ended
/// it with its child.
const STOP_WAIT: Duration = Duration::from_secs(KILL_GRACE * 3);
/// The poll between the stop's reads of the job.
const STOP_POLL: Duration = Duration::from_millis(200);

/// What the job reports when it ends.
#[derive(Debug, Clone, Serialize)]
pub struct RunReply {
    pub item: String,
    pub round_id: String,
    pub run_dir: String,
    pub outcome: Option<StageOutcome>,
    pub closed_now: bool,
    /// The run's wall time from its `timing` record, where the run left
    /// one and this run closed the stage.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seconds: Option<u64>,
    /// The notice's owner word after this run: `sent`, `unsent:<cause>`,
    /// `owed` where this run's send is held, or the mark an earlier run
    /// left.
    pub notice: Option<String>,
    /// Why this run's send is held: the fleet record's read error, or the
    /// send whose answer is not known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub held: Option<String>,
}

/// The transition environment at this moment: the command's stamp re-read
/// after a wait that outlasted the one it started with (the child run for
/// the run's whole bound; the stop's wait for the job), so the close, its
/// notice's send and the stop's finishing transition carry the clock of the
/// close, never the launch's. The nonce and the owner identity stay the
/// command's. Defect this holds against: a stage `end` stamped at the job's
/// launch second, and a sentinel time later than it read as out of bounds.
#[allow(
    clippy::disallowed_methods,
    reason = "the job's and the stop's own stamp at their close, the command's clock read again after a wait the command's first stamp predates"
)]
fn env_now(env: &Env) -> Env {
    let since_epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    Env {
        now_secs: since_epoch.as_secs(),
        now_nanos: since_epoch.as_nanos(),
        nonce: env.nonce,
        owner: env.owner.clone(),
    }
}

/// The run's stage under `run_dir`, with the item's stages.
fn stage_of(path: &Path, run_dir: &str) -> Result<(Vec<Stage>, usize)> {
    let snapshot = load(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
    })?;
    let stages = snapshot.view::<ItemState>(path)?.stages;
    let index = stages
        .iter()
        .position(|s| s.kind == StageKind::Validate && s.run_dir.as_deref() == Some(run_dir))
        .ok_or_else(|| Error::RunUnadmitted {
            run_dir: run_dir.to_owned(),
        })?;
    Ok((stages, index))
}

/// The run's `start` record field.
fn start_field(run_dir: &Path, key: &str) -> Option<String> {
    let text = fs::read_to_string(run_dir.join("start")).ok()?;
    text.lines()
        .find_map(|l| l.strip_prefix(key).and_then(|r| r.strip_prefix('=')))
        .map(str::to_owned)
}

/// Run the executor as this job's bounded child, in a session of its own
/// so it leads its own process group: the group the child's own
/// `job_unit_end` tears down, and the one `validate stop` ends by its
/// recorded pid through the launcher. The bound is the cap plus the
/// child's own teardown grace; a child the bound ends leaves no sentinel,
/// which reads as lost.
#[allow(
    clippy::disallowed_methods,
    reason = "the validation job's one run of the kept executor through the one runner, bounded by the run's cap"
)]
fn run_child(settings: &Settings, worktree: &Path, run_dir: &Path, cap_secs: u64) {
    let cli = settings.dev_validate_cli.display().to_string();
    let rd = run_dir.display().to_string();
    let place = Place {
        cwd: Some(worktree),
        env: &[],
    };
    let _ = host::run_tagged_in(
        "validate",
        "setsid",
        Path::new("setsid"),
        "child",
        &["-w", &cli, "--child", "--run-dir", &rd],
        place,
        Duration::from_secs(cap_secs + 2 * KILL_GRACE),
    );
}

/// What the run left: the outcome its sentinel named, or, with no sentinel
/// (the child was ended before it wrote one), `stopped` where the stage
/// records the intentional stop and `lost` where nothing recorded an
/// intent; the sentinel's own `at=` time where it parses; the run's wall
/// time from its `timing` record; and the command's last `validate:`
/// selection line, which `--record` reads the lanes and selection from.
struct Left {
    outcome: StageOutcome,
    at: Option<u64>,
    seconds: Option<u64>,
    selection: Option<String>,
}

/// Read the run directory once the child ended, `stopped` being whether the
/// stage records a `validate stop`.
fn read_left(run_dir: &Path, stopped: bool) -> Left {
    let log = run_dir.join("log");
    let sentinel = match fs::read_to_string(run_dir.join("exit")) {
        Ok(text) => Some(text.trim_end().to_owned()),
        Err(_) => None,
    };
    let selection = fs::read_to_string(&log).ok().and_then(|text| {
        text.lines()
            .rfind(|l| l.starts_with("validate:"))
            .and_then(|l| l.split(' ').find_map(|w| w.strip_prefix("selection=")))
            .map(str::to_owned)
    });
    let outcome = match sentinel.as_deref().and_then(validate::sentinel_outcome) {
        Some(word) => word,
        None if stopped => StageOutcome::Stopped,
        None => StageOutcome::Lost,
    };
    let at = sentinel.as_deref().and_then(|line| {
        line.split(' ')
            .find_map(|f| f.strip_prefix("at="))
            .and_then(clock::epoch_secs)
    });
    let seconds = fs::read_to_string(run_dir.join("timing"))
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|l| l.strip_prefix("seconds="))
                .and_then(|s| s.parse().ok())
        });
    Left {
        outcome,
        at,
        seconds,
        selection,
    }
}

/// How a notice's send went: the owner word to mark the stage with, or a
/// send held with its cause, the stage left owed for the next walk (a send
/// whose outcome is not known, one the lane's record refuses for now, or a
/// fleet record that cannot be read to route it).
enum NoticeSend {
    Marked(String),
    Held(String),
}

/// Send the end notice `text` to the lane of `item` and answer the word its
/// mark records. The fleet record picks the route. A session lane takes the
/// `orch-runtime send` owner, which records the directive owed before the
/// CLI and settles it under its own reconcile, so an irreversible send is
/// never retried blindly. Every other lane takes the mailbox's outbound
/// directive route, `lane-mail send --item ITEM --directive --file F
/// --delivery-id <key>`, which writes the lane's own inbox (`to-lane.jsonl`)
/// and judges the key under the lock, so a replay after a lost mark lands
/// once and answers `delivery-repeated`. The mark is `sent` on a receipt or
/// a repeated delivery, and `unsent:<cause>` where the route refused or
/// never started: recorded, never a reason to hold the close. The send is
/// held where its answer is not known, the replay under the key landing at
/// most once, and where the fleet record cannot be read, since the mailbox
/// route would send to a session lane with no owed record. The file the
/// program reads the notice from is this walker's own scratch,
/// `<key>.<the request's stamp>.notice`, created exclusively and removed by
/// this walker alone, so a second walker of the same notice (the owed walk
/// meeting the job's send in flight) never removes the file the first's
/// program is about to read; the record carries the key, never the file.
#[allow(
    clippy::disallowed_methods,
    reason = "the end notice's file, this walker's own under the state directory, created exclusively for the mailbox program to read and removed by this walker after its send"
)]
fn send_notice(
    settings: &Settings,
    item: &str,
    key: &str,
    text: &str,
    env: &Env,
    locking: Locking,
) -> NoticeSend {
    use std::io::Write;
    let dir = settings.state_dir.join("validate");
    if let Err(e) = fs::create_dir_all(&dir) {
        return NoticeSend::Marked(format!("unsent:notice-dir:{e}"));
    }
    let path = dir.join(format!("{key}.{}.notice", env.round_id()));
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .and_then(|mut file| file.write_all(format!("{text}\n").as_bytes()));
    if let Err(e) = written {
        return NoticeSend::Marked(format!("unsent:notice-write:{e}"));
    }
    let mark = match lane_record(settings, item) {
        Ok(Some(lane)) if lane.session_channel() => {
            send_session(settings, &lane, key, &path, env, locking)
        }
        Ok(Some(_) | None) => send_directive(settings, item, key, &path),
        Err(e) => NoticeSend::Held(format!("fleet:{}: {e}", e.key())),
    };
    let _ = fs::remove_file(&path);
    mark
}

/// The lane of `item` from the fleet record where one stands. No fleet, or
/// one with no record for `item`, is no session lane: the mailbox route
/// then writes a local inbox, which is the channel every non-cloud lane
/// reads. A fleet that cannot be read is `Err`: it may hold a session lane.
#[allow(
    clippy::disallowed_methods,
    reason = "the notice send's one read of the fleet record, to route a cloud session lane to its own send owner"
)]
fn lane_record(settings: &Settings, item: &str) -> Result<Option<Lane>> {
    let fleet = state::fleet_path(&settings.state_dir);
    let Some(snapshot) = state::load(&fleet)? else {
        return Ok(None);
    };
    let fleet = FleetState::view(&fleet, &snapshot.doc)?;
    Ok(fleet.lanes.into_iter().find(|l| l.item == item))
}

/// The mailbox's outbound directive to a non-session lane, keyed by the run.
#[allow(
    clippy::disallowed_methods,
    reason = "the validation job's one outbound send of the lane's end notice through the mailbox program, keyed by the run so a replay lands once"
)]
fn send_directive(settings: &Settings, item: &str, key: &str, file: &Path) -> NoticeSend {
    match Mailbox::new(settings.lane_mail_cli.clone())
        .bounded(NOTICE_TIMEOUT)
        .send_directive(item, None, false, file, Some(key), None)
    {
        Ok(Sent::Mailbox { .. } | Sent::Repeated { .. }) => NoticeSend::Marked("sent".to_owned()),
        // The program routed the lane to its session itself: the send's own
        // result marks it.
        Ok(Sent::Session { send }) => NoticeSend::Marked(session_mark(send.result)),
        // Nothing was appended: the program never started, or refused by
        // its own key before writing any mailbox.
        Err(
            refusal @ (Refusal::NotStarted { .. }
            | Refusal::Exit {
                status: Some(_),
                keyed: Some(_),
                ..
            }),
        ) => NoticeSend::Marked(format!("unsent:{refusal}")),
        // No answer, a signal, an exit with no keyed line or a receipt that
        // does not decode: the append may stand.
        Err(
            refusal @ (Refusal::Unanswered { .. } | Refusal::Exit { .. } | Refusal::Reply { .. }),
        ) => NoticeSend::Held(refusal.to_string()),
    }
}

/// The owner word a session send's result marks the stage with: delivered
/// is `sent`; an archived session or a failed send is terminal, the stage
/// marked `unsent:session:<result>` and never retried blindly (the lane's
/// `directive_send` keeps the receipt for the hosted stall close).
fn session_mark(result: SendResult) -> String {
    match result {
        SendResult::Sent => "sent".to_owned(),
        SendResult::Archived => "unsent:session:archived".to_owned(),
        SendResult::Failed => "unsent:session:failed".to_owned(),
    }
}

/// The session send owner for a cloud lane, keyed by the notice:
/// `send::run_keyed` reads the lane's `directive_send` under this key inside
/// its owed write, under the store's lock, so a replay (the stage still owed
/// when the owed walk or the job's own retry meets it) takes what this
/// notice's own send already settled, with no CLI call, whichever walker's
/// settle it was: a send made `sent` and a found `sent` both mark `sent`;
/// `archived` or `failed`, made or found, takes the terminal mark; a send
/// found owed under this key is held until it settles (the verb's reconcile,
/// or the operator's mark after the watch's `directive-send-unsettled` line),
/// and one found unreadable is held too, never a reason to act. A refusal
/// (the send's outcome unknown, another send still owed on the lane, the
/// lane's record moved) holds the stage owed and sends nothing. The residual,
/// stated and not claimed exactly-once: a crash after this send's settle,
/// then another send to the same lane, then the replay, sends the notice
/// twice, a repeated line in the session and not a harm.
fn send_session(
    settings: &Settings,
    lane: &Lane,
    key: &str,
    file: &Path,
    env: &Env,
    locking: Locking,
) -> NoticeSend {
    let fleet = state::fleet_path(&settings.state_dir);
    match crate::send::run_keyed(&fleet, &lane.item, file, settings, env, locking, key) {
        Ok(Keyed::Sent(sent)) => NoticeSend::Marked(session_mark(sent.send.result)),
        Ok(Keyed::Found(KeyedSend::Settled(result))) => NoticeSend::Marked(session_mark(result)),
        Ok(Keyed::Found(KeyedSend::Owed)) => NoticeSend::Held("session:owed".to_owned()),
        Ok(Keyed::Found(KeyedSend::Unreadable)) => {
            NoticeSend::Held("session:unreadable".to_owned())
        }
        Err(e) => NoticeSend::Held(format!("session:{}: {e}", e.key())),
    }
}

/// The run id a run directory's name carries.
fn run_id_of(run_dir: &str) -> &str {
    let name = Path::new(run_dir)
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or(run_dir);
    name.strip_prefix("dev-validate-").unwrap_or(name)
}

/// Send the stage's owed notice and mark it: the owner word written, or
/// `owed` with the hold's cause where the send is held and the stage left
/// for the next walk.
fn send_and_mark(
    path: &Path,
    settings: &Settings,
    item: &str,
    stage: &Stage,
    env: &Env,
    locking: Locking,
) -> Result<(String, Option<String>)> {
    let (Some(notice), Some(run_dir), Some(round_id)) =
        (&stage.notice, &stage.run_dir, &stage.round_id)
    else {
        return Ok((String::new(), None));
    };
    let to = notice.to.as_deref().unwrap_or(item);
    let mark = match send_notice(settings, to, &notice.key, &notice.text, env, locking) {
        NoticeSend::Marked(mark) => mark,
        NoticeSend::Held(cause) => return Ok((state::NOTICE_OWED.to_owned(), Some(cause))),
    };
    let marked = apply(
        path,
        Validate::Mark(MarkNotice {
            round_id: round_id.clone(),
            run_dir: run_dir.clone(),
            owner: mark,
        }),
        env,
        locking,
    )?;
    Ok(match marked {
        Validated::Mark(m) => (m.owner, None),
        Validated::Start(_) | Validated::Launch(_) | Validated::End(_) | Validated::Stop(_) => {
            (String::new(), None)
        }
    })
}

/// The job's main: run the executor, close the stage, send the notice.
pub fn run(
    settings: &Settings,
    item: &str,
    round: &str,
    run_dir: &str,
    env: &Env,
    locking: Locking,
) -> Result<RunReply> {
    let path = state::item_path(&settings.state_dir, item);
    let (stages, index) = stage_of(&path, run_dir)?;
    let stage = &stages[index];
    let Some(proof) = &stage.proof else {
        return Err(Error::RunUnstarted {
            run_dir: run_dir.to_owned(),
        });
    };
    if stage.end.is_some() {
        // A second run of the same job: the close stands, nothing is sent.
        return Ok(RunReply {
            item: item.to_owned(),
            round_id: round.to_owned(),
            run_dir: run_dir.to_owned(),
            outcome: stage.outcome,
            closed_now: false,
            seconds: None,
            notice: stage.notice.as_ref().map(|n| n.owner.clone()),
            held: None,
        });
    }
    let run_dir_path = PathBuf::from(run_dir);
    let worktree = start_field(&run_dir_path, "worktree")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            run_dir_path
                .parent()
                .and_then(Path::parent)
                .map(Path::to_path_buf)
                .unwrap_or_default()
        });
    run_child(settings, &worktree, &run_dir_path, proof.cap_secs);
    // The close's own clock: the child ran for up to the run's bound.
    let env = &env_now(env);
    // The stage as it stands once the child ended: a `validate stop` that
    // ended the child recorded its intent on the stage before it did.
    let (stages, index) = stage_of(&path, run_dir)?;
    let left = read_left(&run_dir_path, stages[index].stop.is_some());
    let notice = validate::end_notice(run_id_of(run_dir), run_dir, left.outcome);
    let ended = apply(
        &path,
        Validate::End(RecordEnd {
            round_id: round.to_owned(),
            run_dir: run_dir.to_owned(),
            outcome: left.outcome,
            end: left.at,
            seconds: left.seconds,
            selection: left.selection,
            notice: Some(notice),
        }),
        env,
        locking,
    )?;
    let Validated::End(ended) = ended else {
        unreachable!("an end reports its end")
    };
    if !ended.closed_now {
        return Ok(RunReply {
            item: item.to_owned(),
            round_id: round.to_owned(),
            run_dir: run_dir.to_owned(),
            outcome: ended.outcome,
            closed_now: false,
            seconds: None,
            notice: ended.notice_owner,
            held: None,
        });
    }
    // The notice is on disk as `owed`; the send follows and the mark after.
    let (stages, index) = stage_of(&path, run_dir)?;
    let (notice, held) = send_and_mark(&path, settings, item, &stages[index], env, locking)?;
    Ok(RunReply {
        item: item.to_owned(),
        round_id: round.to_owned(),
        run_dir: run_dir.to_owned(),
        outcome: ended.outcome,
        closed_now: true,
        seconds: ended.seconds,
        notice: Some(notice),
        held,
    })
}

/// Send every end notice the item's closed runs still record `owed`: the
/// continuation a crash between the close and the send left behind, run
/// before the item's `reconcile-round` transition. A mark the store refused
/// leaves the notice owed, so the next reconcile sends again; the mailbox
/// reads a repeat within its window as sent, and a session send is read by
/// its key on the lane's record.
pub fn deliver_owed(settings: &Settings, path: &Path, env: &Env, locking: Locking) -> Result<()> {
    let Some(snapshot) = load(path)? else {
        return Ok(());
    };
    let item = path
        .file_stem()
        .and_then(OsStr::to_str)
        .and_then(|s| s.strip_prefix("workflow-state-"))
        .unwrap_or_default()
        .to_owned();
    let stages = snapshot.view::<ItemState>(path)?.stages;
    for stage in stages.iter().filter(|s| {
        s.kind == StageKind::Validate
            && s.end.is_some()
            && s.notice.as_ref().is_some_and(state::Notice::owed)
    }) {
        if let Err(e) = send_and_mark(path, settings, &item, stage, env, locking) {
            // The store refused the mark: the notice stays owed for the
            // next reconcile, and this one is not failed over it.
            let _ = e;
        }
    }
    Ok(())
}

// --- The stop -------------------------------------------------------------------

/// What `validate stop` reports.
#[derive(Debug, Clone, Serialize)]
pub struct StopReply {
    pub item: String,
    pub round_id: String,
    pub run_dir: String,
    /// The stop as the stage records it: this call's or an earlier one's.
    pub stop: Stop,
    pub recorded_now: bool,
    /// The launcher's runner word for the job, `systemd` or `setsid`.
    pub runner: String,
    pub ended: JobEnded,
    pub job: JobState,
    /// The stage after the finishing transition: its word where it closed,
    /// whether it is closed, and its notice's owner word.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<StageOutcome>,
    pub closed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notice: Option<String>,
}

/// What the launcher's stop did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum JobEnded {
    /// The unit was stopped, or the child's group torn down.
    Signalled,
    /// Nothing to end: the manager has no such unit, or the recorded child
    /// is not this run's executor any more.
    AlreadyGone,
}

/// How the job read after the stop's bounded wait.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum JobState {
    Gone,
    /// Still live after the wait: it owns its close, or the next reconcile
    /// does.
    Live,
    /// The identity read could not say; the stage stays as it stood.
    Unreadable,
}

/// End the run's job through the launcher's own stop, `job-unit stop-job
/// RECORD PID ARGV_GLOB`: the unit by the exact name its record carries, the
/// setsid group by the child's pid while that pid still runs this run's
/// executor (a pid the system reused is left alone). Exit 0 ended it, 1 found
/// nothing to end; anything else is the launcher's keyed line, refused
/// `stop-failed`.
#[allow(
    clippy::disallowed_methods,
    reason = "the stop's one ask of the job launcher to end the run's job by its recorded identity, after the stop was recorded on the stage"
)]
fn end_job(settings: &Settings, run_dir: &str, job: &ValidateJob) -> Result<JobEnded> {
    let pid = fs::read_to_string(Path::new(run_dir).join("pid"))
        .map(|t| t.trim().to_owned())
        .unwrap_or_default();
    let name = Path::new(run_dir)
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or(run_dir);
    let glob = format!("* --child --run-dir */tmp/{name}");
    let out = host::run_tagged(
        "validate",
        "job-unit",
        &settings.job_unit,
        "stop-job",
        &["stop-job", &job.record, &pid, &glob],
        STOP_TIMEOUT,
    )
    .map_err(|e| Error::ValidateStopFailed {
        run_dir: run_dir.to_owned(),
        cause: e.to_string(),
    })?;
    match out.status.code() {
        Some(0) => Ok(JobEnded::Signalled),
        Some(1) => Ok(JobEnded::AlreadyGone),
        _ => Err(Error::ValidateStopFailed {
            run_dir: run_dir.to_owned(),
            cause: host::stderr_text(&out)
                .lines()
                .next()
                .unwrap_or_default()
                .to_owned(),
        }),
    }
}

/// Wait, bounded, for the job to read gone by its recorded identity.
#[allow(
    clippy::disallowed_methods,
    reason = "the stop's bounded wait for the job it ended to read gone, polling the one identity reader"
)]
fn wait_job_gone(job: &ValidateJob) -> JobState {
    let deadline = Instant::now() + STOP_WAIT;
    loop {
        let state = match job_ended(job) {
            Some(true) => return JobState::Gone,
            Some(false) => JobState::Live,
            None => JobState::Unreadable,
        };
        if Instant::now() >= deadline {
            return state;
        }
        std::thread::sleep(STOP_POLL);
    }
}

/// The round's reconcile, the one finishing transition a gone job's stage
/// takes (`ops::item::reconcile_round`): a job gone with no sentinel and the
/// stage's stop recorded closes `stopped` with the notice owed in the same
/// write; a live job keeps its stage.
#[allow(
    clippy::disallowed_methods,
    reason = "the stop's one finishing transition, the round's reconcile through the one dispatcher"
)]
fn reconcile(path: &Path, round_id: &str, env: &Env, locking: Locking) -> Result<()> {
    ops::apply(
        path,
        &Request::ReconcileRound(ReconcileRound {
            round_id: round_id.to_owned(),
        }),
        env,
        locking,
    )?;
    Ok(())
}

/// Stop a started run: the stop recorded on its open stage first (a
/// record before the effect; refused
/// `run-closed` on a closed stage, `run-unstarted` on one with no runtime
/// job), the job ended by its recorded identity through the launcher, a
/// bounded wait for the job to read gone, then the finishing transition and
/// the owed walk: on the unit route the manager ended the job with its
/// child, so the reconcile closes the stage `stopped` with the notice owed
/// and the walk sends it; on the setsid route the job outlives its child's
/// group and makes the same close itself, the first closer winning. `item`
/// names the record; with none, the run directory finds it.
pub fn stop(
    settings: &Settings,
    item: Option<&str>,
    run_dir: &str,
    env: &Env,
    locking: Locking,
) -> Result<StopReply> {
    let item = match item {
        Some(item) => item.to_owned(),
        None => item_of_run_dir(&settings.state_dir, run_dir)?.0,
    };
    let path = state::item_path(&settings.state_dir, &item);
    let (stages, index) = stage_of(&path, run_dir)?;
    let round_id = stages[index].round_id.clone().unwrap_or_default();
    let stopped = apply(
        &path,
        Validate::Stop(RecordStop {
            round_id: round_id.clone(),
            run_dir: run_dir.to_owned(),
        }),
        env,
        locking,
    )?;
    let Validated::Stop(stopped) = stopped else {
        unreachable!("a stop reports its stop")
    };
    let (stages, index) = stage_of(&path, run_dir)?;
    let Some(job) = stages[index].job.clone() else {
        unreachable!("the stop stands on a started run")
    };
    let ended = end_job(settings, run_dir, &job)?;
    let job_state = wait_job_gone(&job);
    // The finishing transition's own clock: the stop and the wait took time.
    let env = &env_now(env);
    deliver_owed(settings, &path, env, locking)?;
    reconcile(&path, &round_id, env, locking)?;
    deliver_owed(settings, &path, env, locking)?;
    let (stages, index) = stage_of(&path, run_dir)?;
    let stage = &stages[index];
    Ok(StopReply {
        item,
        round_id,
        run_dir: run_dir.to_owned(),
        stop: stopped.stop,
        recorded_now: stopped.recorded_now,
        runner: job.runner.unwrap_or_default(),
        ended,
        job: job_state,
        outcome: stage.outcome,
        closed: stage.end.is_some(),
        notice: stage.notice.as_ref().map(|n| n.owner.clone()),
    })
}
