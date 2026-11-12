//! Error categories. Every failure names the operation that refused and the
//! identity it refused on; a caller routes on the variant, never on the text,
//! and the diagnostic line opens with `key()`. A field value never carries
//! a serializer's or parser's own message: that text is the human line.

use std::path::PathBuf;

use crate::state::{Kind, LaneStatus};

/// The window a walled account was judged on: the
/// projected window where one was projected, else the reading's wall.
#[derive(Debug, Clone, PartialEq)]
pub struct WalledWindow {
    pub pct: f64,
    pub bucket: String,
    /// The projected room, `None` where the judge read the wall alone.
    pub projected_headroom: Option<f64>,
}

/// The end a retired account's refusal names: the
/// day and who stated it, boxed as `WalledWindow` is to keep `Error`
/// small.
#[derive(Debug, Clone, PartialEq)]
pub struct RetiredEnd {
    pub ends: String,
    pub stated_by: String,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{key}: {cause}")]
    Artifact { key: &'static str, cause: String },
    /// A record, lock, process or protocol failure agent-runtime reported.
    #[error(transparent)]
    Runtime(#[from] agent_runtime::Error),
    /// The request's operation belongs to the other kind of state file.
    #[error("{op} applies to the {wanted:?} state, {path} is the {kind:?} state")]
    OpKind {
        op: &'static str,
        path: PathBuf,
        kind: Kind,
        wanted: Kind,
    },
    #[error("{path}: not an operation request: {cause}")]
    Request { path: PathBuf, cause: String },
    /// The request reads an external system before its one transition, so
    /// `apply` cannot run it as a transition; `verify::run` does.
    #[error("{op} reads before it writes and is not applied as a transition")]
    OpNotTransition { op: &'static str },
    /// A `verify-head` or `verify-pr` field is not the form its reads pin:
    /// `repo` is `owner/name`, `base` a branch name, `head` a full lowercase
    /// 40-hex commit id, `pr` a positive number. The value stays in this
    /// text: it may hold whitespace.
    #[error("{field} {value:?} is not the form the verification's reads pin")]
    VerifyRequestInvalid { field: &'static str, value: String },
    /// A `verify-pr` request names a pull request that is closed or
    /// merged; nothing on it is awaited, so no verdict is read or recorded.
    #[error("pull request #{pr} is {state}, not open")]
    PullRequestNotOpen { pr: u64, state: &'static str },
    #[error("no lane record names {item}")]
    LaneMissing { item: String },
    /// The lane is in flight, so a launch or an adoption would make a second
    /// controller for the item.
    #[error("the lane for {item} is {}", status.word())]
    LaneLive { item: String, status: LaneStatus },
    #[error("the lane for {item} is done")]
    LaneDone { item: String },
    /// A lane launch names a `kind` or `surface` the one local tmux route
    /// cannot run; refused before any intent persists.
    #[error("a {kind:?} {surface:?} lane is not a local tmux window")]
    HostUnsupported { kind: String, surface: String },
    #[error("no round stage carries {round_id}")]
    RoundUnknown { round_id: String },
    /// No validation stage of the round names the run directory.
    #[error("no validation stage of round {round_id} names {run_dir}")]
    RunUnknown { round_id: String, run_dir: String },
    /// A later round of the same kind superseded this one; its result is
    /// kept as history and is not the current round's.
    #[error("round {round_id} was superseded")]
    RoundSuperseded { round_id: String },
    /// The word is none a verification record carries (`pass`, `fail`,
    /// `none`). `pending` is a wait that ended without a result,
    /// no verdict about the head, so it is refused rather than recorded.
    #[error("{verdict:?} is not a verification verdict")]
    VerdictInvalid { verdict: String },
    // The session send's refusals.
    /// A directive send on a lane whose channel is a mailbox, not a cloud
    /// session: the mailbox send is the mailbox's own.
    #[error("the lane for {item} runs in no cloud session; send through lane-mail")]
    LaneChannel { item: String },
    /// A send stands owed on the lane: its receipt settles it first, since a
    /// second send would queue the directive twice.
    #[error(
        "a directive send to {item} stands owed; the reconcile settles it from its kept receipt"
    )]
    DirectiveSendOwed { item: String },
    /// A receipt offered to a lane whose record owes no send: the record
    /// was replaced under the send, and takes no stale receipt.
    #[error("no directive send to {item} is owed, so the receipt is not recorded")]
    DirectiveSendUnowed { item: String },
    /// The mailbox program gave no receipt and no refusal of its own: whether
    /// the directive reached the session is unknown, and the record stands
    /// owed so no repeat queues it twice.
    #[error("the directive send to {item} earned no receipt and stands owed: {cause}")]
    DirectiveSendUnsettled { item: String, cause: String },
    /// An `accept-result` end outside `[start, now]` of the stage it closes.
    #[error("round {round_id}: end {end} is outside the stage's [{start}, {now}]")]
    EndOutOfRange {
        round_id: String,
        end: u64,
        start: u64,
        now: u64,
    },
    /// A minted admission needs the item's recorded worktree to name the run
    /// directory under, and the record carries none.
    #[error("{path}: the item records no worktree, so no run directory can be minted")]
    WorktreeUnrecorded { path: PathBuf },
    /// An `accept-result` end names an artifact whose modification time
    /// cannot be read.
    #[error("{path}: the end artifact's modification time cannot be read: {cause}")]
    EndArtifactUnreadable { path: PathBuf, cause: String },
    #[error("{path}: no handoff record stands")]
    HandoffNone { path: PathBuf },
    /// A handoff record with other content stands; the named fields differ.
    /// A repeat of the same content is a no-op, and replacing the record
    /// is asked for with `supersede: true`.
    #[error("{path}: a handoff record with other {} stands", fields.join(","))]
    HandoffDiffers { path: PathBuf, fields: Vec<String> },
    #[error("handoff written_at {written_at:?} is not ISO 8601 UTC")]
    HandoffWrittenAtInvalid { written_at: String },
    #[error("handoff written_at {written_at} is later than the clock at {now}")]
    HandoffWrittenAtFuture { written_at: String, now: String },
    /// A refusal that came after the request's intent was persisted: the
    /// intent stands for the reconcile to settle, so a caller reads the
    /// request as unconfirmed, never as refused. The key and fields are the
    /// inner refusal's, with `persisted_intent` added.
    #[error("{error}")]
    Persisted { intent: String, error: Box<Error> },
    /// The cap the request's kind is bounded by admits no further lane:
    /// `occupancy` slots charge it, `lanes` of them lane records, `cap` is
    /// the bound and `setting` the key that raises it.
    #[error("the {setting} cap of {cap} is reached: {occupancy} slots charge it ({lanes} lanes)")]
    CapReached {
        occupancy: u32,
        cap: u32,
        lanes: u32,
        setting: &'static str,
    },
    /// The cap could not be judged: a source the count reads failed. A count
    /// missing a lane admits one lane too many, so none is made.
    #[error("the cap count could not read its {read} at {path}: {cause}")]
    CapUnreadable {
        /// Which input failed: `claims` or `records`.
        read: &'static str,
        path: PathBuf,
        cause: String,
    },
    /// A wall relaunch names the account the wall spent.
    #[error("the lane for {item} would run on the spent account {account}")]
    AccountSpent { item: String, account: String },
    /// The launch's account is walled on its projection: the
    /// accounts judge found no room for one more lane on it, the lane this
    /// relaunch replaces left out. The figures are the record's as the
    /// released launcher read them, in its line's words.
    #[error("the lane for {item} would run on {account}, walled at {} on its {} window", window.pct, window.bucket)]
    AccountWalled {
        item: String,
        account: String,
        model: String,
        window: Box<WalledWindow>,
    },
    /// The launch's account is one the provider reserved: never picked,
    /// whatever its room. The refusal names the word,
    /// never the wall's figures.
    #[error("the lane for {item} would run on {account}, which is reserved")]
    AccountReserved {
        item: String,
        account: String,
        model: String,
    },
    /// The launch's account's stated end has come: not picked from that
    /// day. The refusal names the day and who stated it, never the wall's
    /// figures.
    #[error("the lane for {item} would run on {account}, retired since {}", end.ends)]
    AccountRetired {
        item: String,
        account: String,
        model: String,
        end: Box<RetiredEnd>,
    },
    /// Nothing measured the launch's account: an unread window is not an
    /// empty one.
    #[error("the lane for {item} would run on {account}, whose window nothing measured ({status})")]
    AccountUnmeasured {
        item: String,
        account: String,
        model: String,
        status: String,
        detail: String,
    },
    /// The accounts judge could not judge the launch's account: the
    /// listing or the fleet unread. Never a verdict, never an admission.
    #[error("the lane for {item} would run on {account}, which could not be judged: {cause}")]
    AccountUnjudged {
        item: String,
        account: String,
        cause: String,
    },
    /// The lane's recorded harness still runs under its recorded start,
    /// whatever its status word reads: a relaunch would make a second one.
    #[error("the lane for {item} still runs its harness (pid {pid})")]
    HarnessLive { item: String, pid: u64 },
    /// Whether the lane's recorded harness runs could not be read; nothing
    /// that would start or end a harness is authorized on an unknown.
    #[error("the lane for {item}: harness pid {pid} could not be read: {cause}")]
    HarnessUnreadable {
        item: String,
        pid: u64,
        cause: String,
    },
    /// The identity an adoption names holds no live process, so there is
    /// no execution to bind the lane to.
    #[error("the lane for {item}: pid {pid} holds no live process under its start")]
    IdentityGone { item: String, pid: u64 },
    /// A close request names both a terminal verdict and a no-landing
    /// disposition; one ground authorizes a close.
    #[error("the close of {item} names two grounds")]
    CloseGroundAmbiguous { item: String },
    /// A reservation's `until` is not an ISO 8601 UTC stamp after the clock.
    #[error("the reservation on {item} lapses at {until:?}, not a stamp after now")]
    ReservationInvalid { item: String, until: String },
    /// A request bound to an earlier attempt of the lane: its `session_since`
    /// is not the record's, so it changes nothing.
    #[error("the lane for {item} is attempt {current:?}, not {session_since:?}")]
    AttemptStale {
        item: String,
        session_since: String,
        current: Option<String>,
    },
    /// A park the lane's host cannot take: a local lane has no sandbox to
    /// stop (`park-lane`, `park-refused reason=local`).
    #[error("the lane for {item} cannot be parked: {reason}")]
    ParkRefused { item: String, reason: &'static str },
    /// A path the item touches is held by a lane whose harness runs or is
    /// about to; nothing is launched until the holder
    /// ends, or the brief names the file in scope.
    #[error("the lane for {item} would touch {file}, which {holder} holds")]
    LaunchOverlap {
        item: String,
        file: String,
        holder: String,
    },
    /// A holder of a path the item touches could not be judged: its
    /// identity, its touched set or its branch could not be read. An
    /// unreadable holder is unknown, never free.
    #[error("the holder {holder} of a path {item} touches: its {read} could not be read: {cause}")]
    HolderUnreadable {
        item: String,
        holder: String,
        read: &'static str,
        cause: String,
    },
    /// The item is a container by its body: children, or
    /// the `agent:multi` label, outside an in-PR bundle. Never launched.
    #[error("{item} is not launchable: {cause}")]
    ItemIneligible { item: String, cause: &'static str },
    /// The item, or a container ancestor of it, holds a launch blocker the
    /// tracker reports open: nothing is launched before the blockers land.
    #[error("{item} is blocked from launch by {}", blockers.join(","))]
    LaunchBlocked { item: String, blockers: Vec<String> },
    /// The item's ancestor chain could not be read whole, so the launch
    /// blockers are unknown: `read` names the item whose read failed.
    #[error("the launch blockers of {item} could not be read at {read}: {cause}")]
    LaunchBlockedUnread {
        item: String,
        read: String,
        cause: String,
    },
    /// A source of the item's touched set could not be read: its body, a
    /// Location line naming no path, the brief file, or the change-scope
    /// paths over the named range.
    #[error("the touched set of {item} could not be read from its {read}: {cause}")]
    TouchedUnreadable {
        item: String,
        read: &'static str,
        cause: String,
    },
    /// The open pull requests of the item's repository, holders of the
    /// paths they change, could not be read whole: a
    /// checkout naming no GitHub repository, a failed `gh` call, a pull
    /// request or its files answering nothing, a member outside the
    /// documented shape, or a files list short of the pull request's
    /// count. An unread inventory is never an empty one.
    #[error(
        "the open pull requests of {repo}, holders of paths {item} touches, could not be read: {read}: {cause}"
    )]
    HoldersUnreadable {
        item: String,
        repo: String,
        read: &'static str,
        cause: String,
    },
    // The validation run's refusals (`validate start|run`).
    /// A wider mode than the declaration's narrowest was asked for with no
    /// cause.
    #[error("validate mode {mode} on a project declaring {narrower} needs a cause")]
    ModeCauseMissing {
        mode: &'static str,
        narrower: &'static str,
    },
    /// A range or ci request names no base commit.
    #[error("validate mode {mode} needs a base")]
    ModeBaseRequired { mode: &'static str },
    /// The project declares no whole battery.
    #[error(
        "{setting} is empty; set it in kendex.settings.toml [env] to the project's full test, lint and typecheck command"
    )]
    ValidateCmdEmpty { setting: &'static str },
    /// The base does not name a commit in the worktree.
    #[error(
        "the base {base} names no commit in the worktree; a run compares only from the base it was given, so name a new base with the authority that named this one"
    )]
    BaseInvalid { base: String },
    /// A run of the round stands open with its job recorded: one run at a
    /// time per round.
    #[error("round {round_id}: the run {run_dir} is still open")]
    RunLive { round_id: String, run_dir: String },
    /// No item records an admitted run under the directory.
    #[error("no admitted validation run names {run_dir}")]
    RunUnadmitted { run_dir: String },
    /// The stage names a run the runtime never started: no job on it.
    #[error("the run {run_dir} was never started by the runtime")]
    RunUnstarted { run_dir: String },
    // The stop's refusals (`validate stop`).
    /// The run's stage is closed: a stop records nothing on it.
    #[error("the run {run_dir} is closed")]
    RunClosed { run_dir: String },
    /// The launcher could not end the run's job; the stop stands recorded
    /// and the job is as the launcher left it.
    #[error("the run {run_dir} could not be stopped: {cause}")]
    ValidateStopFailed { run_dir: String, cause: String },
    /// The launcher refused the job, or the run's files could not be
    /// written; the stage is closed `stopped` with the cause.
    #[error("the run {run_dir} could not be started: {cause}")]
    ValidateLaunchFailed { run_dir: String, cause: String },
    /// A read the start needs before it records anything failed: the
    /// worktree's HEAD, its snapshot, a scratch directory.
    #[error("the validation start could not read its {read}: {cause}")]
    ValidateUnreadable { read: &'static str, cause: String },
    /// The selector's estimate exceeds the bound; nothing is recorded.
    #[error("the selector expects {expected}s, over the {bound}s bound")]
    OverBound { expected: u64, bound: u64 },
    // The acceptance's authorization and its summary record.
    /// An acceptance for a directed item names no owner directive, or
    /// another's; the item's key carries the id it needs.
    #[error("the acceptance names no owner directive {directive}")]
    AuthorizationMissing { directive: String },
    /// The stage closed under another authorization than the request
    /// names, or under none: the authorization is part of the acceptance's
    /// identity, and a close is never re-authorized.
    #[error("round {round_id} was accepted under another authorization")]
    AuthorizationDiffers { round_id: String },
    /// The item records another Completion Summary comment than the
    /// request names; the recorded id stands, so one comment is updated in
    /// place and none is orphaned.
    #[error("{path}: the summary comment {recorded} is recorded, not {given}")]
    SummaryCommentDiffers {
        path: PathBuf,
        recorded: String,
        given: String,
    },
    /// The standing scheduler's refusals: its claim, its records and its
    /// duties (`watch run|status|stop|log`).
    #[error(transparent)]
    Watch(#[from] WatchError),
}

/// Why the fleet watch refused: one family, keyed `watch-*`. The claim is
/// bound to a process identity, so a refusal names the pid
/// and start it read.
#[derive(Debug, thiserror::Error)]
pub enum WatchError {
    /// A runner whose identity reads live holds the claim on this fleet
    /// state; a second runner is refused and nothing is written.
    #[error("{path}: a watch runs on this fleet state (pid {pid}, start {start})")]
    Running {
        path: PathBuf,
        pid: u32,
        start: String,
    },
    /// Whether the claim's identity still runs could not be read; an
    /// unreadable owner is never taken over.
    #[error("{path}: the claim's process (pid {pid}) could not be read: {cause}")]
    ClaimUnreadable {
        path: PathBuf,
        pid: u32,
        cause: String,
    },
    /// A record of the watch could not be written or read: the claim, its
    /// argv, the event log, the baseline or the stop request.
    #[error("{path}: the watch record could not be {op}: {cause}")]
    Record {
        path: PathBuf,
        op: &'static str,
        cause: String,
    },
    /// A stop was requested and the claimed runner had not released its
    /// claim within the bound; it may still be finishing a duty.
    #[error("the watch (pid {pid}, start {start}) did not release its claim within the bound")]
    StopTimeout { pid: u32, start: String },
    /// The claim no longer names the running runner: another start wrote
    /// the record. The run ends and the record stands as its holder wrote it.
    #[error("{path}: the claim no longer names this runner (pid {pid}, start {start})")]
    ClaimMoved {
        path: PathBuf,
        pid: u32,
        start: String,
    },
    /// The runner has no readable identity of its own to claim with: a
    /// claim without one could not be told live from dead.
    #[error("no readable process identity to claim the watch with")]
    IdentityUnreadable,
}

impl WatchError {
    pub fn key(&self) -> &'static str {
        match self {
            WatchError::Running { .. } => "watch-running",
            WatchError::ClaimUnreadable { .. } => "watch-claim-unreadable",
            WatchError::Record { .. } => "watch-record",
            WatchError::StopTimeout { .. } => "watch-stop-timeout",
            WatchError::ClaimMoved { .. } => "watch-claim-moved",
            WatchError::IdentityUnreadable => "watch-identity-unreadable",
        }
    }

    fn fields(&self) -> Vec<(String, String)> {
        let pair = |k: &str, v: String| (k.to_owned(), v);
        match self {
            WatchError::Running { path, pid, start } => vec![
                pair("path", path.display().to_string()),
                pair("pid", pid.to_string()),
                pair("start", start.clone()),
            ],
            WatchError::ClaimUnreadable { path, pid, .. } => vec![
                pair("path", path.display().to_string()),
                pair("pid", pid.to_string()),
            ],
            WatchError::Record { path, op, .. } => vec![
                pair("path", path.display().to_string()),
                pair("op", (*op).to_owned()),
            ],
            WatchError::StopTimeout { pid, start } => {
                vec![pair("pid", pid.to_string()), pair("start", start.clone())]
            }
            WatchError::ClaimMoved { path, pid, start } => vec![
                pair("path", path.display().to_string()),
                pair("pid", pid.to_string()),
                pair("start", start.clone()),
            ],
            WatchError::IdentityUnreadable => Vec::new(),
        }
    }
}

impl Error {
    /// The stable key a diagnostic line opens with.
    pub fn key(&self) -> &'static str {
        match self {
            Error::Artifact { key, .. } => key,
            Error::Runtime(e) => e.key(),
            Error::OpKind { .. } => "op-kind",
            Error::Request { .. } => "request-invalid",
            Error::OpNotTransition { .. } => "op-not-transition",
            Error::VerifyRequestInvalid { .. } => "verify-request-invalid",
            Error::PullRequestNotOpen { .. } => "pr-not-open",
            Error::LaneMissing { .. } => "lane-missing",
            Error::LaneLive { .. } => "lane-live",
            Error::LaneDone { .. } => "lane-done",
            Error::HostUnsupported { .. } => "host-unsupported",
            Error::RoundUnknown { .. } => "round-unknown",
            Error::RunUnknown { .. } => "run-unknown",
            Error::RoundSuperseded { .. } => "round-superseded",
            Error::VerdictInvalid { .. } => "verdict-invalid",
            Error::LaneChannel { .. } => "lane-channel",
            Error::DirectiveSendOwed { .. } => "directive-send-owed",
            Error::DirectiveSendUnowed { .. } => "directive-send-unowed",
            Error::DirectiveSendUnsettled { .. } => "directive-send-unsettled",
            Error::EndOutOfRange { .. } => "end-out-of-range",
            Error::WorktreeUnrecorded { .. } => "worktree-unrecorded",
            Error::EndArtifactUnreadable { .. } => "end-artifact-unreadable",
            Error::HandoffNone { .. } => "handoff-none",
            Error::HandoffDiffers { .. } => "handoff-differs",
            Error::HandoffWrittenAtInvalid { .. } => "handoff-written-at-invalid",
            Error::HandoffWrittenAtFuture { .. } => "handoff-written-at-future",
            Error::Persisted { error, .. } => error.key(),
            Error::CapReached { .. } => "cap-reached",
            Error::CapUnreadable { .. } => "cap-unreadable",
            Error::AccountSpent { .. } => "account-spent",
            Error::AccountWalled { .. } => "account-walled",
            Error::AccountReserved { .. } => "account-reserved",
            Error::AccountRetired { .. } => "account-retired",
            Error::AccountUnmeasured { .. } => "account-unmeasured",
            Error::AccountUnjudged { .. } => "account-unjudged",
            Error::HarnessLive { .. } => "harness-live",
            Error::HarnessUnreadable { .. } => "harness-unreadable",
            Error::IdentityGone { .. } => "identity-gone",
            Error::CloseGroundAmbiguous { .. } => "close-ground-ambiguous",
            Error::ReservationInvalid { .. } => "reservation-invalid",
            Error::AttemptStale { .. } => "attempt-stale",
            Error::ParkRefused { .. } => "park-refused",
            Error::LaunchOverlap { .. } => "launch-overlap",
            Error::HolderUnreadable { .. } => "holder-unreadable",
            Error::ItemIneligible { .. } => "item-ineligible",
            Error::LaunchBlocked { .. } => "launch-blocked",
            Error::LaunchBlockedUnread { .. } => "launch-blocked-unread",
            Error::TouchedUnreadable { .. } => "touched-unreadable",
            Error::HoldersUnreadable { .. } => "holders-unreadable",
            Error::ModeCauseMissing { .. } => "mode-cause-missing",
            Error::ModeBaseRequired { .. } => "mode-base-required",
            Error::ValidateCmdEmpty { .. } => "empty-validate-cmd",
            Error::BaseInvalid { .. } => "invalid-base",
            Error::RunLive { .. } => "run-live",
            Error::RunUnadmitted { .. } => "run-unadmitted",
            Error::RunUnstarted { .. } => "run-unstarted",
            Error::RunClosed { .. } => "run-closed",
            Error::ValidateStopFailed { .. } => "stop-failed",
            Error::ValidateLaunchFailed { .. } => "launch-failed",
            Error::ValidateUnreadable { .. } => "validate-unreadable",
            Error::OverBound { .. } => "over-bound",
            Error::AuthorizationMissing { .. } => "authorization-missing",
            Error::AuthorizationDiffers { .. } => "authorization-differs",
            Error::SummaryCommentDiffers { .. } => "summary-comment-differs",
            Error::Watch(e) => e.key(),
        }
    }

    /// The values the refusal acted on, as `field=value` pairs. A cause or
    /// a parser's message is not among them.
    pub fn fields(&self) -> Vec<(String, String)> {
        let pair = |k: &str, v: String| (k.to_owned(), v);
        match self {
            Error::Artifact { cause, .. } => vec![pair("cause", cause.clone())],
            Error::Runtime(e) => agent_runtime::protocol::Refusal::from(e).fields,
            Error::Request { path, .. } => {
                vec![pair("path", path.display().to_string())]
            }
            Error::OpKind {
                op,
                path,
                kind,
                wanted,
            } => vec![
                pair("op", (*op).to_owned()),
                pair("path", path.display().to_string()),
                pair("kind", kind.word().to_owned()),
                pair("wanted", wanted.word().to_owned()),
            ],
            Error::LaneMissing { item } | Error::LaneDone { item } => {
                vec![pair("item", item.clone())]
            }
            Error::HostUnsupported { kind, surface } => {
                vec![pair("kind", kind.clone()), pair("surface", surface.clone())]
            }
            Error::LaneLive { item, status } => vec![
                pair("item", item.clone()),
                pair("status", status.word().to_owned()),
            ],
            Error::RoundUnknown { round_id } | Error::RoundSuperseded { round_id } => {
                vec![pair("round_id", round_id.clone())]
            }
            Error::RunUnknown { round_id, run_dir } => vec![
                pair("round_id", round_id.clone()),
                pair("run_dir", run_dir.clone()),
            ],
            Error::VerdictInvalid { verdict } => vec![pair("verdict", verdict.clone())],
            Error::OpNotTransition { op } => {
                vec![pair("op", (*op).to_owned())]
            }
            Error::VerifyRequestInvalid { field, .. } => vec![pair("field", (*field).to_owned())],
            Error::PullRequestNotOpen { pr, state } => {
                vec![
                    pair("pr", pr.to_string()),
                    pair("state", (*state).to_owned()),
                ]
            }
            Error::EndOutOfRange {
                round_id,
                end,
                start,
                now,
            } => vec![
                pair("round_id", round_id.clone()),
                pair("end", end.to_string()),
                pair("start", start.to_string()),
                pair("now", now.to_string()),
            ],
            Error::WorktreeUnrecorded { path }
            | Error::HandoffNone { path }
            | Error::EndArtifactUnreadable { path, .. } => {
                vec![pair("path", path.display().to_string())]
            }
            Error::LaneChannel { item }
            | Error::DirectiveSendOwed { item }
            | Error::DirectiveSendUnowed { item }
            | Error::DirectiveSendUnsettled { item, .. } => vec![pair("item", item.clone())],
            Error::HandoffDiffers { path, fields } => vec![
                pair("path", path.display().to_string()),
                pair("fields", fields.join(",")),
            ],
            Error::HandoffWrittenAtInvalid { written_at } => {
                vec![pair("written_at", written_at.clone())]
            }
            Error::HandoffWrittenAtFuture { written_at, now } => vec![
                pair("written_at", written_at.clone()),
                pair("now", now.clone()),
            ],
            Error::Persisted { intent, error } => {
                let mut fields = error.fields();
                fields.push(pair("persisted_intent", intent.clone()));
                fields
            }
            Error::CapReached {
                occupancy,
                cap,
                lanes,
                setting,
            } => vec![
                pair("occupancy", occupancy.to_string()),
                pair("cap", cap.to_string()),
                pair("lanes", lanes.to_string()),
                pair("setting", (*setting).to_owned()),
            ],
            Error::CapUnreadable { read, path, .. } => vec![
                pair("source", (*read).to_owned()),
                pair("path", path.display().to_string()),
            ],
            Error::AccountSpent { item, account } => {
                vec![pair("item", item.clone()), pair("account", account.clone())]
            }
            Error::AccountWalled {
                item,
                account,
                model,
                window,
            } => {
                // The figures as `jq` prints them in the released judge's line: an
                // integral value with no fraction, `none` where none was projected.
                let number = |n: f64| {
                    if n.fract() == 0.0 {
                        format!("{n:.0}")
                    } else {
                        n.to_string()
                    }
                };
                vec![
                    pair("item", item.clone()),
                    pair("account", account.clone()),
                    pair("model", model.clone()),
                    pair("pct", number(window.pct)),
                    pair("bucket", window.bucket.clone()),
                    pair(
                        "projected-headroom",
                        window
                            .projected_headroom
                            .map_or_else(|| "none".to_owned(), number),
                    ),
                ]
            }
            Error::AccountReserved {
                item,
                account,
                model,
            } => vec![
                pair("item", item.clone()),
                pair("account", account.clone()),
                pair("model", model.clone()),
                pair("word", "reserve".to_owned()),
            ],
            Error::AccountRetired {
                item,
                account,
                model,
                end,
            } => vec![
                pair("item", item.clone()),
                pair("account", account.clone()),
                pair("model", model.clone()),
                pair("ends", end.ends.clone()),
                pair("source", end.stated_by.clone()),
            ],
            Error::AccountUnmeasured {
                item,
                account,
                model,
                status,
                detail,
            } => vec![
                pair("item", item.clone()),
                pair("account", account.clone()),
                pair("model", model.clone()),
                pair("status", status.clone()),
                pair("detail", detail.clone()),
            ],
            Error::AccountUnjudged {
                item,
                account,
                cause,
            } => vec![
                pair("item", item.clone()),
                pair("account", account.clone()),
                pair("cause", cause.clone()),
            ],
            Error::HarnessLive { item, pid } | Error::IdentityGone { item, pid } => {
                vec![pair("item", item.clone()), pair("pid", pid.to_string())]
            }
            Error::HarnessUnreadable { item, pid, cause } => vec![
                pair("item", item.clone()),
                pair("pid", pid.to_string()),
                pair("cause", cause.clone()),
            ],
            Error::CloseGroundAmbiguous { item } => vec![pair("item", item.clone())],
            Error::ReservationInvalid { item, until } => {
                vec![pair("item", item.clone()), pair("until", until.clone())]
            }
            Error::AttemptStale {
                item,
                session_since,
                current,
            } => vec![
                pair("item", item.clone()),
                pair("session_since", session_since.clone()),
                pair("current", current.clone().unwrap_or_default()),
            ],
            Error::ParkRefused { item, reason } => {
                vec![
                    pair("item", item.clone()),
                    pair("reason", (*reason).to_owned()),
                ]
            }
            Error::LaunchOverlap { item, file, holder } => vec![
                pair("item", item.clone()),
                pair("file", file.clone()),
                pair("holder", holder.clone()),
            ],
            Error::HolderUnreadable {
                item, holder, read, ..
            } => vec![
                pair("item", item.clone()),
                pair("holder", holder.clone()),
                pair("read", (*read).to_owned()),
            ],
            Error::ItemIneligible { item, cause } => {
                vec![
                    pair("item", item.clone()),
                    pair("cause", (*cause).to_owned()),
                ]
            }
            Error::LaunchBlocked { item, blockers } => {
                vec![
                    pair("item", item.clone()),
                    pair("blockers", blockers.join(",")),
                ]
            }
            Error::LaunchBlockedUnread { item, read, .. } => {
                vec![pair("item", item.clone()), pair("read", read.clone())]
            }
            Error::TouchedUnreadable { item, read, .. } => {
                vec![pair("item", item.clone()), pair("read", (*read).to_owned())]
            }
            Error::HoldersUnreadable {
                item, repo, read, ..
            } => vec![
                pair("item", item.clone()),
                pair("repo", repo.clone()),
                pair("read", (*read).to_owned()),
            ],
            Error::ModeCauseMissing { mode, narrower } => vec![
                pair("mode", (*mode).to_owned()),
                pair("narrower", (*narrower).to_owned()),
            ],
            Error::ModeBaseRequired { mode } => vec![pair("mode", (*mode).to_owned())],
            Error::ValidateCmdEmpty { setting } => vec![pair("setting", (*setting).to_owned())],
            Error::BaseInvalid { base } => vec![pair("base", base.clone())],
            Error::RunLive { round_id, run_dir } => vec![
                pair("round_id", round_id.clone()),
                pair("run_dir", run_dir.clone()),
            ],
            Error::RunUnadmitted { run_dir }
            | Error::RunUnstarted { run_dir }
            | Error::ValidateLaunchFailed { run_dir, .. } => vec![pair("run_dir", run_dir.clone())],
            Error::RunClosed { run_dir } | Error::ValidateStopFailed { run_dir, .. } => {
                vec![pair("run_dir", run_dir.clone())]
            }
            Error::ValidateUnreadable { read, .. } => vec![pair("read", (*read).to_owned())],
            Error::OverBound { expected, bound } => vec![
                pair("expected_secs", expected.to_string()),
                pair("bound", bound.to_string()),
            ],
            Error::AuthorizationMissing { directive } => {
                vec![pair("directive", directive.clone())]
            }
            Error::AuthorizationDiffers { round_id } => vec![pair("round_id", round_id.clone())],
            Error::SummaryCommentDiffers {
                path,
                recorded,
                given,
            } => vec![
                pair("path", path.display().to_string()),
                pair("recorded", recorded.clone()),
                pair("given", given.clone()),
            ],
            Error::Watch(e) => e.fields(),
        }
    }
}

/// A reply or request value that would not serialize; the path names the
/// in-process value, there being no file.
impl From<serde_json::Error> for Error {
    fn from(source: serde_json::Error) -> Self {
        Error::Runtime(agent_runtime::Error::Json {
            path: PathBuf::from("<value>"),
            source,
        })
    }
}

/// An orch refusal crossing back through the engine, which holds no orch
/// type: agent-runtime's own error as it is, any other as agent-runtime's
/// refusal under the same key and fields, so the line it prints keeps its
/// key and fields.
impl From<Error> for agent_runtime::Error {
    fn from(error: Error) -> Self {
        match error {
            Error::Runtime(inner) => inner,
            other => agent_runtime::Error::Refused {
                key: other.key(),
                fields: other.fields(),
            },
        }
    }
}

/// A launch preparation refused by an orch read: the launch's own refusal,
/// crossing as agent-runtime's error under the same key and fields.
impl From<Error> for agent_runtime::effects::prepare::Unready {
    fn from(error: Error) -> Self {
        agent_runtime::effects::prepare::Unready::Refused(error.into())
    }
}

pub type Result<T> = std::result::Result<T, Error>;
