//! The turn end's answer to its harness: the keyed lines the check writes
//! and the shape each harness reads a refusal in. The first line of every
//! text is the contract a reader parses, `lane-mail-check: <key>=<value>`;
//! the English explanation follows it, then the cause a command wrote, and
//! never a bypass.

use std::path::{Path, PathBuf};

use super::Arm;
use super::payload::Caller;

/// The harness an install serves, read from where the install sits, the one
/// place that records it: it decides the shape of every refusal, since
/// Copilot takes its decision as JSON on stdout where the others read the
/// exit status and stderr.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Harness {
    Claude,
    Codex,
    Pi,
    Copilot,
    /// An install directory naming no harness: answered as every harness but
    /// Copilot is.
    Unlisted,
}

impl Harness {
    /// The harness kendex's hook targets put an install under: the claude
    /// copy under `.claude/hooks`, the codex copy under `.codex/hooks`, Pi's
    /// under the `kendex/hooks` segment of `.pi` or of its user root
    /// `.pi/agent`, the project copilot copy under `.github/hooks`. A Pi lane
    /// on a pool account runs under the user root `pi_dir`
    /// (`PI_CODING_AGENT_DIR`) names, compared as physical paths since
    /// either may be spelled through a link. The global copilot copy sits in
    /// an account directory spelled however the operator likes, so it is
    /// known by the registry document `lane-mail-check.json` its install
    /// alone writes beside the hook.
    pub fn of(hook_dir: &Path, pi_dir: Option<&Path>) -> Harness {
        let spelled = hook_dir.to_string_lossy();
        for (suffix, harness) in [
            ("/.claude/hooks", Harness::Claude),
            ("/.codex/hooks", Harness::Codex),
            ("/.pi/kendex/hooks", Harness::Pi),
            ("/.pi/agent/kendex/hooks", Harness::Pi),
            ("/.github/hooks", Harness::Copilot),
        ] {
            if spelled.ends_with(suffix) {
                return harness;
            }
        }
        if let Some(pi_dir) = pi_dir {
            let pi_hooks = std::fs::canonicalize(pi_dir.join("kendex").join("hooks"));
            if let (Ok(pi_hooks), Ok(this)) = (pi_hooks, std::fs::canonicalize(hook_dir))
                && pi_hooks == this
            {
                return Harness::Pi;
            }
        }
        let registry = std::fs::metadata(hook_dir.join("lane-mail-check.json"));
        if registry.is_ok_and(|meta| meta.is_file()) {
            return Harness::Copilot;
        }
        Harness::Unlisted
    }
}

/// The days a Copilot lead record or a pending reading marker stands
/// untouched before a session start prunes it.
pub const LEAD_DAYS: u64 = 30;

/// One keyed line of the catalogue, with the value it names.
pub enum Said {
    /// The argument names no arm the verb judges.
    Arm(String),
    PayloadUnreadable,
    PayloadInvalid,
    /// The git command that failed, as its arguments read.
    Git(String),
    /// The launch marker that is present and no readable plain file.
    Marker(PathBuf),
    ItemInvalid,
    ItemAmbiguous,
    /// A root its launch marker binds holds no mailbox directory.
    MailboxMissing {
        mail_root: PathBuf,
        marker: PathBuf,
        /// The one command that restores the directory; a subagent is told
        /// to report the gap instead.
        command: Option<String>,
    },
    // The caller's identity (`role`): who a session with no lane item is.
    /// The fleet record names this session's pane and a native identity
    /// another session's: the payload's session, the recorded harness and
    /// launch home, each `none` where empty.
    SessionUnbound {
        session: String,
        harness: String,
        home: String,
    },
    /// The heal of the fleet record the caller's key, `<server> <pane>`,
    /// is bound to could not be written.
    RecordUnhealed(String),
    /// Jarvis's own reader could not read the managed session record the
    /// launch names.
    JarvisRecordUnread(PathBuf),
    /// A session in tmux names no pane and none was recovered for it.
    SessionUnjudged,
    /// The file that tells a session once that it is unjudged could not be
    /// written.
    SessionUnjudgedCache(PathBuf),
    /// A Copilot session start naming no session id.
    LeadUnnamed,
    LeadUnrecorded(PathBuf),
    LeadsUnpruned(PathBuf),
    /// A Copilot compaction from a session no lead record names.
    CompactionUnrecorded(String),
    /// The mailbox reader the settings name is no executable.
    Reader(PathBuf),
    /// The settings that name the mailbox reader could not be read.
    ReaderUnsettled,
    /// The reader's peek ended other than with its answer: its exit status,
    /// or the word for a run that gave none.
    Inbox(String),
    InboxHeader,
    InboxEnvelope,
    /// An unread halt refuses this tool call; the lead is shown the one
    /// read that acknowledges it.
    Halt {
        id: String,
        text: String,
        caller: Caller,
        command: String,
    },
    /// The unread lines, as the reader printed them; the read that
    /// acknowledges a halt among them, where the lead is shown it.
    Unread {
        count: usize,
        lines: String,
        command: Option<String>,
    },
    /// A finished Copilot tool call from a session no lead record names.
    CallUnrecorded(String),
    /// The context answer could not be written.
    NoticeUnwritten,
    /// A harness question tool in a launched lane; a subagent is not shown
    /// the route.
    QuestionTool {
        tool: String,
        route: Option<String>,
    },
    /// A lane's turn end with nothing reported since its last judged one.
    Idle {
        item: String,
        routes: Box<Routes>,
        status_file: PathBuf,
    },
    /// The notice an idle continued turn sends its overseer.
    LaneIdle(String),
    IdleNotice(String),
    /// The idle notice's send ended other than with its receipt.
    IdleNoticeUnsent(String),
    IdleRecord(PathBuf),
    IdleStatus(PathBuf),
    IdleUnrecorded(PathBuf),
    IdleHoldUnrecorded(PathBuf),
    IdleNoticeUnrecorded(PathBuf),
    /// The session's own event row could not be written, under the root
    /// of the checkout whose overseer mailbox takes it.
    RowsUnwritten(PathBuf),
    /// A Pi lane's turn row could not be written into its mailbox
    /// directory.
    LaneRowsUnwritten(PathBuf),
    /// A Jarvis launch record could not take this session's stamp.
    JarvisRowsUnwritten(PathBuf),
    /// The reader's events listing ended other than with its answer.
    Events(String),
    EventsEnvelope,
    // The handoff marks' lines (`marks`): a lane's own words, each refusal
    // carrying the instruction that records the handoff.
    /// The settings the marks are judged under could not be loaded.
    HandoffUnanswered,
    /// The workflow state file whose handoff could not be read.
    HandoffUnreadable(String),
    /// A setting the marks read that could not be read, as `KEY`.
    Setting {
        key: &'static str,
        instruction: String,
    },
    /// A setting outside its form, as `KEY=VALUE`.
    SettingRange {
        value: String,
        instruction: String,
    },
    TranscriptUnreadable {
        transcript: String,
        instruction: String,
    },
    TranscriptUnread {
        transcript: String,
        instruction: String,
    },
    /// The transcript whose last usage line the adapter does not read.
    UsageUnread(String),
    /// The model, or the harness, whose compaction point is unverified.
    WindowUnread(String),
    /// The harness whose compaction settings could not be read.
    CompactionUnread(&'static str),
    /// An install naming no harness an adapter reads.
    HarnessUnlisted(PathBuf),
    /// The record a reading could not be written to.
    ContextUnrecorded(PathBuf),
    /// The context mark reached.
    Context {
        tokens: u64,
        window: Option<u64>,
        mark: u32,
        instruction: String,
    },
    /// An attached launch, as `TOOL tokens=N`, at the context mark.
    AgentLaunch {
        value: String,
        instruction: String,
    },
    /// An attached launch past the reserve while an agent is out.
    AgentReserve {
        value: String,
        rows: String,
        codex: bool,
    },
    /// An attached launch past the reserve with the roster unread.
    AgentUnobserved {
        value: String,
        rows: String,
        instruction: String,
    },
    /// An input the attached launch is judged on is unavailable.
    AgentInput {
        value: String,
        instruction: String,
    },
    /// A Copilot reading handed to its usage run and not yet recorded,
    /// named by the pending marker that still stands.
    ReadingPending(PathBuf),
    /// No Copilot reading stands in this record, and the status-line record
    /// did not answer either.
    ReadingUnrecorded(PathBuf),
    /// Why the status-line record did not answer for this session.
    SessionRecord(&'static str),
    /// The stop a Copilot session's status-line record establishes.
    StopCause(&'static str),
    /// A Copilot context reading from a session no lead record names.
    ReadingUnowned(String),
    /// The record a Copilot context reading could not be written to, and
    /// whether the earlier reading standing there was removed.
    ReadingUnkept {
        record: PathBuf,
        removed: bool,
    },
    /// The flag a Copilot lead's automatic compaction could not be written
    /// to.
    CompactionUnflagged(PathBuf),
    /// A context record or compaction flag that stands and cannot be read.
    RecordUnread {
        path: PathBuf,
        instruction: String,
    },
    /// Copilot began compacting the session automatically before a reading
    /// past the mark reached a turn end.
    Compacted {
        instruction: String,
    },
}

/// The commands a lane is told to route a question or a report through,
/// each naming the lane's root, as `bash`'s `printf %q` quotes them.
pub struct Routes {
    pub ask: String,
    pub inbox: String,
    pub notice: String,
}

impl Said {
    fn key(&self) -> (&'static str, String) {
        match self {
            Said::Arm(word) => ("arm", word.clone()),
            Said::PayloadUnreadable => ("payload", "unreadable".to_owned()),
            Said::PayloadInvalid => ("payload", "invalid-json".to_owned()),
            Said::Git(command) => ("git", command.clone()),
            Said::Marker(path) => ("marker", path.display().to_string()),
            Said::ItemInvalid => ("item", "invalid".to_owned()),
            Said::ItemAmbiguous => ("item", "ambiguous".to_owned()),
            Said::MailboxMissing { mail_root, .. } => {
                ("mailbox-missing", mail_root.display().to_string())
            }
            Said::SessionUnbound {
                session,
                harness,
                home,
            } => (
                "session-unbound",
                format!(
                    "{session} harness={harness} home={home} remedy=orch-runtime register --fleet"
                ),
            ),
            Said::RecordUnhealed(key) => ("record-unhealed", key.clone()),
            Said::JarvisRecordUnread(record) => {
                ("jarvis-record-unread", record.display().to_string())
            }
            Said::SessionUnjudged => ("session-unjudged", "missing-pane".to_owned()),
            Said::SessionUnjudgedCache(told) => {
                ("session-unjudged-cache", told.display().to_string())
            }
            Said::LeadUnnamed => ("lead-unrecorded", "none".to_owned()),
            Said::LeadUnrecorded(path) => ("lead-unrecorded", path.display().to_string()),
            Said::LeadsUnpruned(dir) => ("leads-unpruned", dir.display().to_string()),
            Said::CompactionUnrecorded(session) => ("session-unrecorded", session.clone()),
            Said::Reader(path) => ("reader", path.display().to_string()),
            Said::ReaderUnsettled => ("reader", "unsettled".to_owned()),
            Said::Inbox(status) => ("inbox", status.clone()),
            Said::InboxHeader => ("inbox", "header".to_owned()),
            Said::InboxEnvelope => ("inbox", "envelope".to_owned()),
            Said::Halt { id, .. } => ("halt", id.clone()),
            Said::Unread { count, .. } => ("unread", count.to_string()),
            Said::CallUnrecorded(session) => ("session-unrecorded", session.clone()),
            Said::NoticeUnwritten => ("notice", "unwritten".to_owned()),
            Said::QuestionTool { tool, .. } => ("question-tool", tool.clone()),
            Said::Idle { item, .. } => ("idle", item.clone()),
            Said::LaneIdle(item) => ("lane-idle", item.clone()),
            Said::IdleNotice(item) => ("idle-notice", item.clone()),
            Said::IdleNoticeUnsent(status) => ("idle-notice-unsent", status.clone()),
            Said::IdleRecord(path) => ("idle-record", path.display().to_string()),
            Said::IdleStatus(path) => ("idle-status", path.display().to_string()),
            Said::IdleUnrecorded(path) => ("idle-unrecorded", path.display().to_string()),
            Said::IdleHoldUnrecorded(path) => ("idle-hold-unrecorded", path.display().to_string()),
            Said::IdleNoticeUnrecorded(path) => {
                ("idle-notice-unrecorded", path.display().to_string())
            }
            Said::RowsUnwritten(root) => ("rows-unwritten", root.display().to_string()),
            Said::LaneRowsUnwritten(dir) => ("lane-rows-unwritten", dir.display().to_string()),
            Said::JarvisRowsUnwritten(record) => {
                ("jarvis-rows-unwritten", record.display().to_string())
            }
            Said::Events(status) => ("events", status.clone()),
            Said::EventsEnvelope => ("events", "envelope".to_owned()),
            Said::HandoffUnanswered => ("handoff-unanswered", "settings".to_owned()),
            Said::HandoffUnreadable(file) => ("handoff-unreadable", file.clone()),
            Said::Setting { key, .. } => ("setting", (*key).to_owned()),
            Said::SettingRange { value, .. } => ("setting-range", value.clone()),
            Said::TranscriptUnreadable { .. } => ("transcript", "unreadable".to_owned()),
            Said::TranscriptUnread { .. } => ("transcript", "unread".to_owned()),
            Said::UsageUnread(transcript) => ("usage-unread", transcript.clone()),
            Said::WindowUnread(model) => ("window-unread", model.clone()),
            Said::CompactionUnread(harness) => ("compaction-unread", (*harness).to_owned()),
            Said::HarnessUnlisted(dir) => ("harness-unlisted", dir.display().to_string()),
            Said::ContextUnrecorded(path) => ("context-unrecorded", path.display().to_string()),
            Said::Context { tokens, .. } => ("context", tokens.to_string()),
            Said::AgentLaunch { value, .. } => ("agent-launch", value.clone()),
            Said::AgentReserve { value, .. } => ("agent-reserve", value.clone()),
            Said::AgentUnobserved { value, .. } => ("agent-unobserved", value.clone()),
            Said::AgentInput { value, .. } => ("agent-input", value.clone()),
            Said::ReadingPending(marker) => ("reading-pending", marker.display().to_string()),
            Said::ReadingUnrecorded(record) => ("reading-unrecorded", record.display().to_string()),
            Said::SessionRecord(reason) => ("session-record", (*reason).to_owned()),
            Said::StopCause(cause) => ("stop-cause", (*cause).to_owned()),
            Said::ReadingUnowned(session) => ("session-unrecorded", session.clone()),
            Said::ReadingUnkept { record, .. } => {
                ("context-unrecorded", record.display().to_string())
            }
            Said::CompactionUnflagged(flag) => {
                ("compaction-unrecorded", flag.display().to_string())
            }
            Said::RecordUnread { path, .. } => ("record", path.display().to_string()),
            Said::Compacted { .. } => ("compacted", "auto".to_owned()),
        }
    }

    fn explanation(&self) -> String {
        match self {
            Said::Arm(word) => format!(
                "this hook judges a turn end with no argument, a finished tool call with deliver, a tool call about to run with halt, a session start with start, a prompt with prompt, a compaction about to begin with compact and a Copilot session's context reading with usage, writes a session row with row and its event and names whether the session runs in a launched lane with lane; {word} is none of them"
            ),
            Said::PayloadUnreadable => "the hook payload could not be read from stdin".to_owned(),
            Said::PayloadInvalid => "the hook payload is not valid JSON, or a field it reads is not a string; refusing rather than skipping the check".to_owned(),
            Said::Git(command) => format!(
                "git {command} failed, so the repository this lane runs in is unknown. Git reports one status for a directory that is no repository and for metadata it cannot read, so this refuses rather than pass what it could not judge:"
            ),
            Said::Marker(path) => format!(
                "the launch marker {} could not be read, so whether this session is a launched lane is unknown:",
                path.display()
            ),
            Said::ItemInvalid => "LANE_MAIL_ITEM is not spelled in the alphabet a work item is spelled in, ASCII letters, digits, dot, underscore and hyphen, and is never . or ..; refusing rather than reading a mailbox it does not name".to_owned(),
            Said::ItemAmbiguous => "more than one directory under tmp/lane-mail/ lowercases to this branch, so the lane's own mailbox is not decided; set LANE_MAIL_ITEM, or remove the mailbox that is not this lane's".to_owned(),
            Said::MailboxMissing {
                mail_root,
                marker,
                command: None,
            } => format!(
                "the launch marker {} binds this root to a lane, and the lane has no mailbox directory at {}, so no halt or directive its overseer sends can be read; every tool call is refused until the lane lead restores it. Stop, and report this to the lead.",
                marker.display(),
                mail_root.display()
            ),
            Said::MailboxMissing {
                mail_root,
                marker,
                command: Some(command),
            } => format!(
                "the launch marker {} binds this root to a lane, and the lane has no mailbox directory at {}, so no halt or directive its overseer sends can be read; refusing rather than passing a lane its overseer cannot reach. Run exactly this command, the one tool call that passes while this stands; the overseer's first send makes the item's own mailbox under it:\n{command}",
                marker.display(),
                mail_root.display()
            ),
            Said::SessionUnbound { .. } => "the fleet record names this session's pane, and the native session it records is another one, so this session is not the fleet's controller: it reads no overseer mail and judges no controller marks. Registering this session as the controller binds it".to_owned(),
            Said::RecordUnhealed(_) => "the fleet record names this session's pane and lacks a fact this session knows, its tmux server's start, its harness, its launch home or its native session id, and writing those into the record failed; this caller reads no overseer mail, writes no context or gap and judges no marks until a later turn end or tool call records the binding. The writer's words follow:".to_owned(),
            Said::JarvisRecordUnread(_) => "The managed Jarvis session record could not be read. Its succession mark is unjudged:".to_owned(),
            Said::SessionUnjudged => "this session is unjudged because TMUX_PANE is absent and no controller identity could be recovered".to_owned(),
            Said::SessionUnjudgedCache(_) => "the file that keeps this unjudged session from being told again could not be written, so its next event tells it again:".to_owned(),
            Said::LeadUnnamed => "this Copilot session start names no session id this hook can record, so the session's tool calls read as a caller it cannot name: they are handed no mail, and a halt's refusal does not show the command that reads it, which the turn end still hands over".to_owned(),
            Said::LeadUnrecorded(path) => format!(
                "this Copilot session is the lead, and its record at {} could not be written, so its tool calls read as a caller it cannot name: they are handed no mail, and a halt's refusal does not show the command that reads it, which the turn end still hands over:",
                path.display()
            ),
            Said::LeadsUnpruned(dir) => format!(
                "the Copilot lead records or pending reading markers under {} untouched for {LEAD_DAYS} days could not be removed; this session's own lead record stands:",
                dir.display()
            ),
            Said::CompactionUnrecorded(session) => format!(
                "this Copilot compaction's session {session} is no lead session this install recorded at a session start or at a turn end its own transcript proved, so it may be a subagent's compacting its own window: nothing is flagged, and no turn end of the lead's is held for it"
            ),
            Said::Reader(path) => format!(
                "the lane mailbox has a to-lane.jsonl and {} is not an executable reader, so whatever it holds cannot be handed over; install the orch skill beside this hook",
                path.display()
            ),
            Said::ReaderUnsettled => "the lane mailbox has a to-lane.jsonl and the settings that name its reader could not be read, so whatever it holds cannot be handed over:".to_owned(),
            Said::Inbox(status) => format!(
                "the lane mailbox reader exited {status}, so whether messages are waiting is unknown:"
            ),
            Said::InboxHeader => "the lane mailbox reader's --peek output did not open with its count line, so whether messages are waiting is unknown".to_owned(),
            Said::InboxEnvelope => "an envelope the lane mailbox reader printed could not be read, so whether the overseer halted this lane is unknown:".to_owned(),
            Said::Halt {
                text,
                caller: Caller::Subagent,
                ..
            } => format!(
                "the overseer halted the lane this agent works in, and every tool call is refused until the lane lead reads the halt. Stop, and report the halt to the lead:\n{text}"
            ),
            Said::Halt {
                text,
                caller: Caller::Unknown,
                ..
            } => format!(
                "the overseer halted this lane, and every tool call is refused until the lane lead reads the halt. This call's session is no lead session this install recorded, so whether the lane lead or a subagent made it is unknown and the command that reads the halt is not shown here: a subagent stops and reports the halt to the lead, and the lead ends its turn, where it is handed the halt and that command:\n{text}"
            ),
            Said::Halt {
                text,
                caller: Caller::Lead,
                command,
                ..
            } => format!(
                "the overseer halted this lane, and every tool call is refused until the lane reads the halt. Run exactly this command, then act on the directive:\n{command}\n{text}"
            ),
            Said::Unread {
                lines, command, ..
            } => {
                let mut text = format!(
                    "the overseer sent these messages to this lane; act on each as its text directs:\n{lines}"
                );
                if let Some(command) = command {
                    text.push_str(&format!("\na halt among them refuses every tool call but one until the lane runs exactly this command:\n{command}"));
                }
                text
            }
            Said::CallUnrecorded(session) => format!(
                "this finished Copilot tool call's session {session} is no lead session this install recorded at a session start or at a turn end its own transcript proved, so it may be a subagent's: the unread lines are not handed over here and stay unread for the lead's turn end, which hands them over and acknowledges them"
            ),
            Said::NoticeUnwritten => "the notice carrying the lane's unread messages could not be written, so they stay unread for the next point that delivers them:".to_owned(),
            Said::QuestionTool { tool, route: None } => format!(
                "this agent works in a lane, and a lane asks its overseer only through lane mail: {tool} opens a dialog on a pane the overseer cannot see or answer. Stop, and report the question to the lead, which sends it with lane-mail ask."
            ),
            Said::QuestionTool {
                tool,
                route: Some(route),
            } => format!(
                "this session is a lane, and a lane asks its overseer only through lane mail: {tool} opens a dialog on a pane the overseer cannot see or answer. Write the question to a file and send it, then wait on the id the send prints:\n{route}"
            ),
            Said::Idle {
                routes,
                status_file,
                ..
            } => format!(
                "this lane ended its turn with no lane-mail ask or notice sent and no lane status file update since its last judged turn end, no handoff recorded and no halt standing. Read the lane mail and continue the workflow:\n{}\nSend a question through lane mail and wait for its answer:\n{}\nSend changed work as a notice:\n{}\nFor a wait that continues, update this lane status file and end the turn:\n  {}",
                routes.inbox,
                routes.ask,
                routes.notice,
                status_file.display()
            ),
            Said::LaneIdle(_) => "this lane ended a turn that a stop hook's refusal continued, with no lane-mail ask or notice sent and no lane status file update since its last judged turn end, no handoff recorded and no halt standing. This hook refuses that turn end no further.".to_owned(),
            Said::IdleNotice(_) => "this lane ended a continued turn with no lane-mail ask or notice sent and no lane status file update since its last judged turn end. The hook sends that fact to the overseer and ends the turn.".to_owned(),
            Said::IdleNoticeUnsent(status) => format!(
                "this lane ended a turn that a stop hook's refusal continued, with no lane-mail ask or notice sent since its previous turn end, and the notice that tells the overseer so exited {status}, so nobody is told; the turn ends rather than loop on a refusal in a row. The sender's words follow:"
            ),
            Said::IdleRecord(path) => format!(
                "{} is not a plain file holding a sent count, an optional held mark and an optional status file state. The turn ends unjudged and the hook rewrites the record with the current facts.",
                path.display()
            ),
            Said::IdleStatus(path) => format!(
                "{} could not supply this lane's status file update state. The idle check judges the lane mail without that file. The cause follows:",
                path.display()
            ),
            Said::IdleUnrecorded(path) => format!(
                "{}, the count of asks and notices this lane has sent, could not be written, so the next turn end compares against the record it already holds:",
                path.display()
            ),
            Said::IdleHoldUnrecorded(path) => format!(
                "{}, the count of asks and notices this lane has sent, could not take this turn end's hold, so the hold is not made, since one with no record is made again on every continued turn:",
                path.display()
            ),
            Said::IdleNoticeUnrecorded(path) => format!(
                "{}, the count of asks and notices this lane has sent, could not take the idle notice this hook sent, so the next turn end reads that notice as the lane's own send and passes unheld:",
                path.display()
            ),
            Said::RowsUnwritten(_) => "this session's event row could not be written, so the overseer judgement reads what the file already holds or, with no row, the pane, the named fallback; the session goes on:".to_owned(),
            Said::LaneRowsUnwritten(_) => "this Pi lane's turn row could not be written, so oversee-watch and lanes state judge the lane from the rows the file already holds; the lane goes on:".to_owned(),
            Said::JarvisRowsUnwritten(_) => "the Jarvis launch record named above could not take this session's Start stamp, so its launch worker judges this session from its pane until a later tool call, or on Claude Code, Codex or Copilot CLI a turn end, writes it, and on Codex and Copilot CLI holds the brief until a later turn end writes the kickoff's end; the session goes on:".to_owned(),
            Said::Events(status) => format!(
                "the lane mailbox reader's events listing exited {status}, so whether this lane sent anything this turn is unknown; the turn ends unjudged rather than held, because nothing a lane does at its turn end repairs its mailbox:"
            ),
            Said::EventsEnvelope => "an envelope the lane mailbox reader's events listing printed could not be read, so whether this lane sent anything this turn is unknown; the turn ends unjudged rather than held, because nothing a lane does at its turn end repairs its mailbox:".to_owned(),
            Said::HandoffUnanswered => "the handoff marks are judged under this checkout's orch settings, and those settings could not be loaded; both marks are unjudged while that stands, and this turn end is passed rather than held, because the same settings place the one command that records a handoff. Check the settings files, .env.local first. The loader's words are below.".to_owned(),
            Said::HandoffUnreadable(file) => format!(
                "the workflow state at {file} could not be read, so whether this lane has already handed off is unknown; this turn end is passed unjudged rather than held, because the handoff record would be written into that same file and a refusal naming a write that cannot land could never be cleared. Repair or remove it. Anything its reader wrote is below."
            ),
            Said::Setting { key, instruction } => format!(
                "the effective value of {key} could not be read, so the handoff mark it sets is unknown. Recording the handoff ends this refusal:\n{instruction}"
            ),
            Said::SettingRange { value, instruction } => format!(
                "{value} is not a whole number in the range the mark it sets is judged in, so the mark cannot be judged; set it to a number in range. Recording the handoff also ends this refusal:\n{instruction}"
            ),
            Said::TranscriptUnreadable {
                transcript,
                instruction,
            } => format!(
                "the payload's transcript_path {transcript} is not a readable file, so this lane's context use is unknown; refusing rather than letting it run past its handoff mark. Recording the handoff ends this refusal:\n{instruction}"
            ),
            Said::TranscriptUnread {
                transcript,
                instruction,
            } => format!(
                "the transcript {transcript} could not be read, so this lane's context use is unknown. Recording the handoff ends this refusal:\n{instruction}"
            ),
            Said::UsageUnread(transcript) => format!(
                "the last usage line in {transcript} carries none of the field names this harness's adapter reads a token count from, so the context mark is not judged and this gap is reported rather than held; an unread figure is never summed to zero and read as room, and the account mark is judged as usual"
            ),
            Said::WindowUnread(model) => format!(
                "the adapter read this session's tokens but could not verify its compaction point from the effective settings and window for {model}. The reading is below the independent token cap. The percentage mark is unmeasured, and the account mark is judged as usual"
            ),
            Said::CompactionUnread(harness) => format!(
                "the {harness} compaction settings could not be read. The token cap is still judged; the percentage mark has no verified point:"
            ),
            Said::HarnessUnlisted(dir) => format!(
                "{} is no hook directory of a harness the orch adapters read a transcript for, so this session's context is not read and the context mark is not judged, and no Pi turn row is written, so a Pi lane running this install reads unjudged in oversee-watch and lanes state; the gap is reported rather than held",
                dir.display()
            ),
            Said::ContextUnrecorded(path) => format!(
                "this session's context reading could not be written to {}, so lanes context and oversee-succeed still hold the reading before it; the mark itself is judged on the reading this hook took:",
                path.display()
            ),
            Said::Context {
                tokens,
                window,
                mark,
                instruction,
            } => format!(
                "this lane requires handoff under the shared context rule: tokens used={tokens}, effective capacity={}. Handoff is required at 400000 tokens used, or strictly past {mark} percent of the printed window. An empty capacity means unknown. No handoff record stands. Write the handoff so the next session can continue the work.\n{instruction}",
                window.map(|w| w.to_string()).unwrap_or_default()
            ),
            Said::AgentLaunch { value, instruction } => format!(
                "The attached launch {value} reaches the context mark. Use the orch job runner in waiter-launch.md, Launch, or a separate session.\n{instruction}"
            ),
            Said::AgentReserve { value, rows, codex } => format!(
                "The attached launch {value} reaches the context mark less its result reserve, held while an attached agent of this session is still out. The context mark itself is not reached, so no handoff is due: wait in this turn for each attached agent below to return, using the harness wait or result tool.{} Then launch; or use the orch job runner in waiter-launch.md, Launch, or a separate session.{}",
                if *codex {
                    " Call list_agents with no path filter after the wait returns."
                } else {
                    ""
                },
                lined(rows)
            ),
            Said::AgentUnobserved {
                value,
                rows,
                instruction,
            } => format!(
                "The attached launch {value} reaches the context mark less its result reserve, and whether an attached agent of this session is still out cannot be read here, so no wait this hook can observe clears it. The context mark itself is not reached. Use the orch job runner in waiter-launch.md, Launch, or a separate session.{}{}",
                lined(rows),
                lined(instruction)
            ),
            Said::AgentInput { value, instruction } => format!(
                "The attached launch cannot be judged because {value} is unavailable. Repair that input, or use the orch job runner in waiter-launch.md, Launch, or a separate session.\n{instruction}"
            ),
            Said::ReadingPending(marker) => format!(
                "a context reading of this Copilot session was handed to its usage hook run and is not recorded yet, since its pending marker {} still stands after 5 seconds: the run is still going, or it failed, which the session timeline names under a kendex-lane-context: or lane-mail-check: warning. So this turn end judges the context unmeasured, never the earlier record as room; the gap is reported rather than held, and the next reading recorded removes the marker.",
                marker.display()
            ),
            Said::ReadingUnrecorded(record) => format!(
                "no context reading of this Copilot session stands in {}, and the statusLine session record its fallback reads did not answer either, as the session-record line with this one names, so its context is unmeasured and the context mark is not judged; the gap is reported rather than held, and never read as room. The first reader is the kendex-lane-context Copilot extension open-terminal installs in the lane's COPILOT_HOME, which records a reading at each model call of the session. A `kendex-lane-context:` or `lane-mail-check:` warning in the session timeline is the gap that reader met. None means the extension did not run: check that <COPILOT_HOME>/extensions/kendex-lane-context/extension.mjs stands, that enabledFeatureFlags.EXTENSIONS is true in that home's settings.json, and Copilot's own log.",
                record.display()
            ),
            Said::SessionRecord(reason) => format!(
                "this Copilot session has no context reading from the kendex-lane-context extension, so it is read from the record its statusLine command, copilot-statusline, writes under the account directory, and that record did not answer for this session: {reason}. The context mark is not judged and the gap is reported rather than held; the account mark is judged as usual. Set statusLine in the account's settings.json to run copilot-statusline with a refreshInterval under two minutes."
            ),
            Said::StopCause(_) => "this Copilot session's record reports allow_all_enabled false: enterprise managed settings, for its account or for its machine, block the allow-all mode, so every tool call waits on a permission prompt nobody answers. The orch copilot-runtime reference names the remedy".to_owned(),
            Said::ReadingUnowned(session) => format!(
                "this Copilot context reading's session {session} is no lead session this install recorded at a session start or at a turn end its own transcript proved, so the reading is recorded nowhere and the session's turn end reports its context unmeasured under reading-unrecorded; once a turn end whose transcript proves the session the lead's records it, its later readings are recorded"
            ),
            Said::ReadingUnkept {
                record,
                removed: true,
            } => format!(
                "this Copilot session's context reading could not be written to {}, and no earlier reading stands there now, so its next turn end reports the context unmeasured under reading-unrecorded, never judging an older figure as room, until a later reading is recorded. The cause follows:",
                record.display()
            ),
            Said::ReadingUnkept {
                record,
                removed: false,
            } => format!(
                "this Copilot session's context reading could not be written to {}, and the earlier reading standing there could not be removed either, so its next turn end still judges that older figure, which can lie below the mark this reading crossed, until a later reading is recorded; repair the directory. The causes follow:",
                record.display()
            ),
            Said::CompactionUnflagged(flag) => format!(
                "for the operator: Copilot began compacting this fleet session automatically, the backstop handoff mark, and this hook could not flag it because {} could not be used, so no turn end of this session will hold it for the compaction. Tell the session to write its handoff record and end, or end it and relaunch the item. The cause follows:",
                flag.display()
            ),
            Said::RecordUnread { path, instruction } => format!(
                "the context record {} could not be read, so whether this Copilot session is past its handoff mark is unknown; refusing rather than letting it run on. Recording the handoff ends this refusal:\n{instruction}",
                path.display()
            ),
            Said::Compacted { instruction } => format!(
                "this lane requires handoff: Copilot began compacting this session automatically, its preCompact hook naming trigger auto, before a context reading past the handoff mark reached a turn end. Nothing after that compaction is trusted, so start no new work and write the handoff from durable state, the workflow state, git and the PR, never from the conversation the compaction summarised. No handoff record stands. Then end the session, so the next one continues the work.\n{instruction}"
            ),
        }
    }

    /// The whole text: the keyed line, its explanation and, where a command
    /// wrote one, the cause under them. No trailing newline.
    pub fn text(&self, cause: &str) -> String {
        let (key, value) = self.key();
        let mut text = format!("lane-mail-check: {key}={value}\n{}", self.explanation());
        let cause = cause.trim_end_matches('\n');
        if !cause.is_empty() {
            text.push('\n');
            text.push_str(cause);
        }
        text
    }
}

/// `text` on a line of its own, nothing where it is empty.
fn lined(text: &str) -> String {
    if text.is_empty() {
        String::new()
    } else {
        format!("\n{text}")
    }
}

/// What a refusal of `text` puts on stdout and the exit status it takes.
/// A session start and a prompt are never held: the text is a report at
/// exit 0. On Copilot a turn end is held with `{"decision":"block"}` at
/// exit 0, the one form its reference gives for agentStop; a tool call is
/// denied with `permissionDecision` under the exit 2 that denies on its
/// own, so the call is refused whichever of the two the CLI reads first;
/// and a finished tool call is handed `additionalContext` at exit 0, since
/// its reference parses stdout only at exit 0. Every other harness and arm
/// takes the exit status 2 and stderr alone. `arm` is `None` where the
/// argument itself was refused.
pub fn refusal(harness: Harness, arm: Option<&Arm>, text: &str) -> (String, i32) {
    if matches!(arm, Some(Arm::Start | Arm::Prompt)) {
        return (String::new(), 0);
    }
    if harness == Harness::Copilot {
        match arm {
            Some(Arm::Stop) => {
                let answer = serde_json::json!({"decision": "block", "reason": text});
                return (format!("{answer}\n"), 0);
            }
            Some(Arm::Halt) => {
                let answer = serde_json::json!({
                    "permissionDecision": "deny",
                    "permissionDecisionReason": text,
                });
                return (format!("{answer}\n"), 2);
            }
            Some(Arm::Deliver) => {
                let answer = serde_json::json!({"additionalContext": text});
                return (format!("{answer}\n"), 0);
            }
            Some(
                Arm::ModelSwitch
                | Arm::Compact
                | Arm::Usage
                | Arm::Lane
                | Arm::Row { .. }
                | Arm::Start
                | Arm::Prompt,
            )
            | None => {}
        }
    }
    (String::new(), 2)
}

/// What a hand-over of `text` puts on stdout, at exit 0: Claude Code, Codex
/// and Pi read it under `hookSpecificOutput.additionalContext` beside the
/// `event`'s name, Copilot as a top-level `additionalContext`, which its
/// reference appends to the tool result the model sees after postToolUse
/// and injects at a sessionStart. A caller that acknowledges the lines
/// itself, once its own send returns, is handed the acknowledgement's words
/// beside the context as `kendex_ack`.
pub fn context(harness: Harness, event: &str, text: &str, ack: Option<&[String]>) -> String {
    let mut answer = if harness == Harness::Copilot {
        serde_json::json!({"additionalContext": text})
    } else {
        serde_json::json!({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}})
    };
    if let Some(ack) = ack {
        answer["kendex_ack"] = serde_json::json!(ack);
    }
    format!("{answer}\n")
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the rows plant install directories, a registry document and a link"
)]
mod tests {
    use super::*;

    /// Each install directory kendex's hook targets write, read by its
    /// spelling; a Pi pool account's root read through a link; the global
    /// Copilot install by its registry document; any other directory names
    /// no harness.
    #[test]
    fn the_install_directory_names_its_harness() {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        for (spelled, want) in [
            ("p/.claude/hooks", Harness::Claude),
            ("p/.codex/hooks", Harness::Codex),
            ("p/.pi/kendex/hooks", Harness::Pi),
            ("h/.pi/agent/kendex/hooks", Harness::Pi),
            ("p/.github/hooks", Harness::Copilot),
            ("p/.claude/hooks/x", Harness::Unlisted),
            ("p/hooks", Harness::Unlisted),
        ] {
            assert_eq!(Harness::of(&root.join(spelled), None), want, "{spelled}");
        }
        let pool = root.join("pool");
        std::fs::create_dir_all(pool.join("kendex/hooks")).unwrap();
        let link = root.join("spelled-elsewhere");
        std::os::unix::fs::symlink(pool.join("kendex/hooks"), &link).unwrap();
        assert_eq!(Harness::of(&link, Some(&pool)), Harness::Pi);
        assert_eq!(Harness::of(&link, Some(&root)), Harness::Unlisted);
        let account = root.join("account/hooks");
        std::fs::create_dir_all(&account).unwrap();
        assert_eq!(Harness::of(&account, None), Harness::Unlisted);
        std::fs::write(account.join("lane-mail-check.json"), "{}").unwrap();
        assert_eq!(Harness::of(&account, None), Harness::Copilot);
    }
}
