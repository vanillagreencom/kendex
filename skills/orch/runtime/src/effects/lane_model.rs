//! A fleet lane's model recovery: the claim on the fleet record, the
//! relaunch composed from the lane's record, then a detached job that
//! retires the predecessor through the close route and launches its
//! replacement, marking the switch's row as it goes. The job runs apart
//! from the caller's process group, since the caller is as often as not
//! the turn end of the harness the close stops. Everything the caller is
//! told comes before anything stops: a refused claim, a record no relaunch
//! can be composed from, a job the launcher refused.
//!
//! A hosted lane's predecessor stop is the item's own, on its host, where
//! no fleet record stands: its job stops the process group the launch
//! recorded while the record still names the leader the switch read and,
//! where that group still stands or another leads it, keeps the failure on
//! the item's handoff.

use std::path::{Path, PathBuf};

use agent_runtime::effects::job;
use agent_runtime::harness::Harness;
use agent_runtime::journal::Env;
use agent_runtime::record::Locking;
use serde::Serialize;
use serde_json::{Value, json};

use super::refused;
use crate::error::Result;
use crate::ops::lane_model::{
    Mark, RecoverLaneModel, RecoveryRecorded, StopFailure, StopModelPredecessor,
};
use crate::ops::{self, Report, Request};
use crate::settings::Settings;
use crate::state::Lane;
use crate::watch::lanes::{Composed, Composition, compose_relaunch};
use agent_runtime::process::Stop;

/// The files a recovery keeps beside the fleet state, as a relaunch names
/// them: its brief and requests, its job's record and its log.
const STEM: &str = "model-recovery";

/// The recovery's job, run by `bash -c`: the close, then the `starting`
/// mark, then the launch, then its `replaced` or `failed` mark, each through
/// the runtime's entry from the lane's checkout, its output appended to the
/// log. The close and the launch exit
/// by their effects' outcomes: only a confirmed close goes on to the
/// launch, and a launch whose outcome is still open (75) leaves the row
/// `starting` for its intent's reconcile, an attempt the limit counts once
/// its replacement switches again.
const JOB_LINE: &str = r#"log=$1 cwd=$2 runtime=$3 state=$4; shift 4; exec >>"$log" 2>&1; cd -- "$cwd" || exit 1; "$runtime" --state-dir "$state" op --fleet --effect-exit --request "$1"; rc=$?; if [ "$rc" -ne 0 ]; then printf 'model-recovery=stop-failed exit=%s\n' "$rc"; exit "$rc"; fi; "$runtime" --state-dir "$state" op --fleet --request-json "$2" || exit; "$runtime" --state-dir "$state" op --fleet --effect-exit --request "$3"; rc=$?; [ "$rc" -ne 75 ] || exit 75; mark=$5; [ "$rc" -ne 0 ] || mark=$4; "$runtime" --state-dir "$state" op --fleet --request-json "$mark" || exit; exit "$rc""#;

/// A recovery or a predecessor stop whose job started: the launcher's
/// answer and the job's log.
#[derive(Debug, Clone, Serialize)]
pub struct Started {
    pub job: job::Launch,
    pub log: PathBuf,
}

/// The turn end's recovery of the fleet lane its switch was acquired on,
/// admitted under these settings as the command admits a request, then run
/// as [`run`] runs the command's.
pub fn start(
    settings: &Settings,
    fleet: &Path,
    request: &RecoverLaneModel,
    env: &Env,
    locking: Locking,
) -> Result<Started> {
    let claim = RecoverLaneModel {
        mark: None,
        limit: None,
        ..request.clone()
    };
    ops::admit(
        &Request::RecoverLaneModel(Box::new(claim.clone())),
        settings,
    )?;
    recover(settings, fleet, &claim, env, locking)
}

/// The command's entry for `request`, a recovery or its job's mark, on the
/// fleet state at `path`; the reply is what it recorded or started.
pub fn run(
    path: &Path,
    request: &RecoverLaneModel,
    settings: &Settings,
    env: &Env,
    locking: Locking,
) -> Result<Value> {
    match request.mark {
        None => Ok(serde_json::to_value(recover(
            settings, path, request, env, locking,
        )?)?),
        Some(_) => {
            let marked = Request::RecoverLaneModel(Box::new(RecoverLaneModel {
                limit: None,
                ..request.clone()
            }));
            Ok(serde_json::to_value(super::lane_operation::apply_request(
                path, &marked, env, locking,
            )?)?)
        }
    }
}

fn recover(
    settings: &Settings,
    path: &Path,
    request: &RecoverLaneModel,
    env: &Env,
    locking: Locking,
) -> Result<Started> {
    let item = request.item.as_str();
    // A hosted lane's harness, and its turn end, run on its host, where the
    // predecessor stop is the item's own; this machine's fleet record never
    // names the caller's pane for one.
    if let Some(host) = lane_of(path, item)?
        .and_then(|lane| lane.host)
        .filter(|host| !host.is_empty() && host != "local")
    {
        return Err(refused(
            "model-recovery-hosted",
            &[("item", item), ("host", &host)],
        ));
    }
    let claim = Request::RecoverLaneModel(Box::new(RecoverLaneModel {
        mark: None,
        limit: Some(settings.model_recovery_limit.get()?),
        ..request.clone()
    }));
    let applied = super::lane_operation::apply_request(path, &claim, env, locking)?;
    let Report::RecoverLaneModel(recorded) = applied.report else {
        unreachable!("a recovery's claim reports its claim")
    };
    if let RecoveryRecorded::Claim {
        recoveries,
        limit,
        limited: true,
        ..
    } = *recorded
    {
        return Err(refused(
            "model-recovery-limit",
            &[
                ("item", item),
                ("recoveries", &recoveries.to_string()),
                ("limit", &limit.to_string()),
            ],
        ));
    }
    let unprepared = |cause: &str| {
        refused(
            "model-recovery-unprepared",
            &[("item", item), ("cause", cause)],
        )
    };
    let lane = lane_of(path, item)?.ok_or_else(|| unprepared("lane-missing"))?;
    let harness = lane
        .harness
        .as_deref()
        .and_then(Harness::parse)
        .ok_or_else(|| unprepared("harness-unrecorded"))?;
    if lane.model.as_deref().is_none_or(str::is_empty) {
        return Err(unprepared("model-unrecorded"));
    }
    let Composed { cwd, close, launch } = compose_relaunch(
        &lane,
        harness,
        &Composition {
            stem: STEM,
            account: lane.account.as_deref().filter(|a| !a.is_empty()),
            exclude: None,
            brief: continuation,
            ground: json!({"reason": "model-switch", "source": "model-recovery", "interrupt": true}),
        },
        &settings.state_dir,
    )
    .map_err(|cause| unprepared(&cause))?;
    let mark = |mark: Mark| {
        json!({
            "op": "recover-lane-model",
            "item": item,
            "session": request.session,
            "launch_identity": request.launch_identity,
            "mark": mark,
        })
        .to_string()
    };
    let log = settings.state_dir.join(format!("{STEM}-{item}.log"));
    let record = settings.state_dir.join(format!("{STEM}-{item}.unit"));
    let runtime = crate::watch::overseer::scripts_dir(&settings.roots.project).join("orch-runtime");
    let words = [
        log.display().to_string(),
        cwd.display().to_string(),
        runtime.display().to_string(),
        settings.state_dir.display().to_string(),
        close.display().to_string(),
        mark(Mark::Starting),
        launch.display().to_string(),
        mark(Mark::Replaced),
        mark(Mark::Failed),
    ];
    let mut argv = vec!["bash", "-c", JOB_LINE, STEM];
    argv.extend(words.iter().map(String::as_str));
    let answer = job::launch_recorded(
        &format!("{STEM}-{item}"),
        &env.now_secs.to_string(),
        &record,
        &argv,
        None,
        job::Bounds::default(),
        &agent_runtime::clock::SystemClock,
    )
    .answer();
    // A launch that may have started is the recovery's: its marks are its
    // outcome, and a second job would race it.
    if let job::Launch::Refused { cause } = &answer {
        return Err(refused(
            "model-recovery-unstarted",
            &[("item", item), ("cause", cause)],
        ));
    }
    Ok(Started { job: answer, log })
}

/// The fleet record's lane for `item`, `None` where none stands.
fn lane_of(path: &Path, item: &str) -> Result<Option<Lane>> {
    Ok(super::fleet(path)?
        .lanes
        .into_iter()
        .find(|l| l.item == item))
}

/// The line a replaced lane's session runs first: read its inbox, then go
/// on. The launch closes it as it closes every lane brief, the harness's
/// arm line among the closing lines.
fn continuation(lane: &Lane, _harness: Harness) -> std::result::Result<String, String> {
    let item = &lane.item;
    Ok(format!(
        "Resume the orch workflow for {item} from where this session stopped. Run .agents/skills/mailbox/scripts/lane-mail inbox --item {item} first and act on every envelope it prints, answers and directives alike, as its text directs.\n"
    ))
}

/// The predecessor stop's job, run by `bash -c`: the runtime's entry on the
/// job's own request, its output appended to the log.
const STOP_LINE: &str = r#"log=$1; shift; exec >>"$log" 2>&1; exec "$@""#;

/// The turn end's stop of a hosted lane's predecessor, admitted under these
/// settings as the command admits a request, then run as
/// [`stop_predecessor_run`] runs the command's.
pub fn stop_predecessor(
    settings: &Settings,
    item_record: &Path,
    request: &StopModelPredecessor,
    env: &Env,
) -> Result<Started> {
    let caller = StopModelPredecessor {
        job: false,
        failure: None,
        ..request.clone()
    };
    ops::admit(
        &Request::StopModelPredecessor(Box::new(caller.clone())),
        settings,
    )?;
    stop_job(settings, item_record, &caller, env)
}

/// The command's entry for `request` on the item's record at `path`: the
/// caller's starts the job; the job's stops the group and keeps a failure.
pub fn stop_predecessor_run(
    path: &Path,
    request: &StopModelPredecessor,
    settings: &Settings,
    env: &Env,
    locking: Locking,
) -> Result<Value> {
    if !request.job {
        return Ok(serde_json::to_value(stop_job(
            settings, path, request, env,
        )?)?);
    }
    let file = request.file.display().to_string();
    let grace = settings.close_grace.get()?;
    let unread = |e: agent_runtime::Error| StopFailure {
        cause: e.key().to_owned(),
        pid: None,
        exit: 1,
    };
    let failure = match agent_runtime::group::read(&request.file) {
        Ok(Some(recorded)) if recorded != request.leader => {
            failed("identity-stale", Some(request.leader.pid))
        }
        Ok(_) => match agent_runtime::group::stop(&request.file, grace) {
            Ok(value) => match serde_json::from_value::<Stop>(value["stop"].clone()) {
                Ok(Stop::Stopped { .. } | Stop::AlreadyGone) => return Ok(value),
                Ok(Stop::Timeout { pid }) => failed("timeout", Some(pid)),
                Ok(Stop::IdentityStale) => failed("identity-stale", None),
                Ok(Stop::Unreadable { pid, .. }) => failed("unreadable", Some(pid)),
                Err(e) => failed(&format!("stop-unread {e}"), None),
            },
            Err(e) => unread(e),
        },
        Err(e) => unread(e),
    };
    let pid = failure
        .pid
        .map_or_else(|| "none".to_owned(), |p| p.to_string());
    let exit = failure.exit.to_string();
    let fields = [
        ("file", file.as_str()),
        ("cause", failure.cause.as_str()),
        ("pid", pid.as_str()),
        ("exit", exit.as_str()),
    ];
    let kept = Request::StopModelPredecessor(Box::new(StopModelPredecessor {
        failure: Some(failure.clone()),
        ..request.clone()
    }));
    if let Err(e) = super::lane_operation::apply_request(path, &kept, env, locking) {
        let cause = e.to_string();
        return Err(refused(
            "model-predecessor-unrecorded",
            &[
                fields[0],
                fields[1],
                fields[2],
                fields[3],
                ("store", cause.as_str()),
            ],
        ));
    }
    Err(refused("model-predecessor-unstopped", &fields))
}

/// A stop outcome that left the group standing, as `agent-runtime process
/// stop` exits for it: 0, the outcome being its answer.
fn failed(cause: &str, pid: Option<u32>) -> StopFailure {
    StopFailure {
        cause: cause.to_owned(),
        pid,
        exit: 0,
    }
}

/// Start the predecessor stop's job: the runtime's entry on the item's
/// record with the job's own request, detached from the caller, whose
/// process group is as often as not the one it stops. Its record and log
/// sit beside the item's record.
fn stop_job(
    settings: &Settings,
    path: &Path,
    request: &StopModelPredecessor,
    env: &Env,
) -> Result<Started> {
    let stem = path.file_stem().unwrap_or_default().to_string_lossy();
    let dir = path.parent().unwrap_or(Path::new("."));
    let log = dir.join(format!("{stem}.predecessor-stop.log"));
    let record = dir.join(format!("{stem}.predecessor-stop.unit"));
    let job = serde_json::to_string(&Request::StopModelPredecessor(Box::new(
        StopModelPredecessor {
            job: true,
            failure: None,
            ..request.clone()
        },
    )))?;
    let runtime = crate::watch::overseer::scripts_dir(&settings.roots.project).join("orch-runtime");
    let words = [
        log.display().to_string(),
        runtime.display().to_string(),
        "--state-dir".to_owned(),
        settings.state_dir.display().to_string(),
        "op".to_owned(),
        "--file".to_owned(),
        path.display().to_string(),
        "--request-json".to_owned(),
        job,
    ];
    let mut argv = vec!["bash", "-c", STOP_LINE, "model-predecessor-stop"];
    argv.extend(words.iter().map(String::as_str));
    let answer = job::launch_recorded(
        &format!("{stem}-predecessor-stop"),
        &env.now_secs.to_string(),
        &record,
        &argv,
        None,
        job::Bounds::default(),
        &agent_runtime::clock::SystemClock,
    )
    .answer();
    if let job::Launch::Refused { cause } = &answer {
        return Err(refused(
            "model-predecessor-unstarted",
            &[
                ("file", &request.file.display().to_string()),
                ("cause", cause),
            ],
        ));
    }
    Ok(Started { job: answer, log })
}
