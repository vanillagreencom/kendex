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
    /// The reader's events listing ended other than with its answer.
    Events(String),
    EventsEnvelope,
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
            Said::Events(status) => ("events", status.clone()),
            Said::EventsEnvelope => ("events", "envelope".to_owned()),
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
            Said::Events(status) => format!(
                "the lane mailbox reader's events listing exited {status}, so whether this lane sent anything this turn is unknown; the turn ends unjudged rather than held, because nothing a lane does at its turn end repairs its mailbox:"
            ),
            Said::EventsEnvelope => "an envelope the lane mailbox reader's events listing printed could not be read, so whether this lane sent anything this turn is unknown; the turn ends unjudged rather than held, because nothing a lane does at its turn end repairs its mailbox:".to_owned(),
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
