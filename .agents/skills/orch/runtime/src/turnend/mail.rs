//! A launched lane's mail at a turn end. Its unread lines hold a turn end
//! and travel as context after a tool call, at a session start and at a
//! prompt; a halt among them refuses every tool call but the one read that
//! acknowledges it; a harness question tool is refused, since a dialog on a
//! pane reaches no overseer; and a turn end with nothing reported since the
//! last judged one is held once. The mailbox package owns the cursor and
//! every read of the boxes ([`crate::mailbox`]); this module decides what
//! the turn end answers.

use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use super::answer::{self, Harness, Routes, Said};
use super::identity::{Lane, shell_quoted};
use super::payload::{Caller, Payload};
use super::{Answer, Arm, Flow, Turn, Vars};
use crate::mailbox::{Mailbox, Noticed, Refusal};
use crate::settings::{self, Flags};

/// The harness question tools by the names their tool-call payloads carry:
/// Claude Code's `AskUserQuestion` and `EnterPlanMode`, whose plan ends in
/// an approval dialog; Codex's `request_user_input`; and the `question`
/// tool pi-questions registers on Pi.
const QUESTION_TOOLS: [&str; 4] = [
    "AskUserQuestion",
    "EnterPlanMode",
    "request_user_input",
    "question",
];

/// The cursor move for the lines an answer carried, made once the answer
/// is written: a run killed before then leaves the lines unread for the
/// next point that delivers them, never consumed unseen.
#[derive(Debug, PartialEq, Eq)]
pub struct Ack {
    reader: PathBuf,
    item: String,
    root: PathBuf,
    count: u64,
}

impl Ack {
    /// Move the cursor; what the reader wrote where it failed, for stderr.
    /// A failed move costs a repeat at the next delivery, never a loss.
    pub(super) fn settle(&self) -> String {
        let mailbox = Mailbox::new(self.reader.clone());
        match mailbox.acknowledge(&self.item, &self.root, self.count) {
            Ok(()) => String::new(),
            Err(refusal) => {
                let mut cause = cause(&refusal);
                if !cause.is_empty() && !cause.ends_with('\n') {
                    cause.push('\n');
                }
                cause
            }
        }
    }
}

/// The lane's unread mail: held at a turn end, refused at a tool call only
/// where a halt stands, handed over as context at the arms that carry one.
/// A session that is no launched lane, or whose mailbox has never been
/// written, has nothing here. The halt arm acknowledges nothing; every
/// other answer that carries the lines moves the cursor past them once
/// written, but a Copilot prompt, whose context the CLI may drop, and a
/// caller that sends the context on itself.
pub(super) fn check(
    turn: &mut Turn,
    vars: &Vars,
    arm: &Arm,
    lane: &Lane,
    payload: &Payload,
) -> Flow {
    let Some(item) = &lane.item else {
        return Ok(());
    };
    // Anything at the path, a dangling link included, goes on to the
    // reader, whose own rule refuses what it cannot read.
    let file = lane.mail_root.join(item).join("to-lane.jsonl");
    if std::fs::symlink_metadata(&file).is_err() || !lane.launched(turn)? {
        return Ok(());
    }
    // Lane mail is the lead's: a subagent's turn end is handed none.
    if *arm == Arm::Stop && turn.caller != Caller::Lead {
        return Ok(());
    }
    let reader = mail_reader(lane, vars).map_err(|(said, cause)| turn.refuse(said, &cause))?;
    let mailbox = Mailbox::new(reader);
    let peeked = mailbox.inbox_peek(item, &lane.root).map_err(|refusal| {
        let said = match &refusal {
            Refusal::Reply {
                cause: "envelope", ..
            } => Said::InboxEnvelope,
            Refusal::Reply { .. } => Said::InboxHeader,
            _ => Said::Inbox(status(&refusal)),
        };
        turn.refuse(said, &cause(&refusal))
    })?;
    if peeked.unread.is_empty() {
        return Ok(());
    }
    // The reader's `--ack` stops short of an unread halt, so no answer here
    // consumes one: it stands until the lane runs the plain read named
    // here, which names the lane's root so it reads this mailbox from any
    // checkout the lane's shell is in.
    let halt = peeked
        .unread
        .iter()
        .map(|(_, envelope)| envelope)
        .find(|envelope| envelope.halt == Some(true));
    let command = halt.map(|_| read_command(mailbox.cli(), item, &lane.root));
    if *arm == Arm::Halt {
        let (Some(halt), Some(command)) = (halt, command) else {
            return Ok(());
        };
        // A subagent is never passed the read, which would clear the lead's
        // halt; a caller the payload leaves unknown is, since it may be the
        // lead whose record could not be written.
        if turn.caller != Caller::Subagent {
            let call = payload
                .command()
                .map_err(|invalid| turn.refuse(Said::PayloadInvalid, &invalid.0))?;
            if call == command {
                return Err(turn.pass());
            }
        }
        let said = Said::Halt {
            id: halt.id().to_owned(),
            text: halt.text.clone().unwrap_or_default(),
            caller: turn.caller,
            command,
        };
        return Err(turn.refuse(said, ""));
    }
    let unread = Said::Unread {
        count: peeked.unread.len(),
        lines: peeked
            .unread
            .iter()
            .map(|(line, _)| line.as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        command: command.filter(|_| turn.caller == Caller::Lead),
    };
    let ack = Box::new(Ack {
        reader: mailbox.cli().to_path_buf(),
        item: item.clone(),
        root: lane.root.clone(),
        count: peeked.count,
    });
    let Some(event) = arm.context_event() else {
        turn.ack = Some(ack);
        return Err(turn.refuse(unread, ""));
    };
    // On Copilot a custom subagent's finished call hands its context to the
    // subagent's own model, so a caller no lead record names is handed
    // nothing and the lines wait for the lead's turn end.
    if turn.caller == Caller::Unknown {
        let session = if payload.session.is_empty() {
            "none"
        } else {
            &payload.session
        };
        turn.note(&Said::CallUnrecorded(session.to_owned()), "");
        return Err(turn.pass());
    }
    let text = unread.text("");
    if payload.ack_by_caller {
        let argv = mailbox.ack_argv(item, &lane.root, peeked.count);
        return Err(hand_over(turn, event, &text, Some(&argv), None));
    }
    let prompt_on_copilot = turn.harness == Harness::Copilot && *arm == Arm::Prompt;
    Err(hand_over(
        turn,
        event,
        &text,
        None,
        (!prompt_on_copilot).then_some(ack),
    ))
}

/// A launched lane's harness question tool, refused after the halt arm has
/// had its say, so a halted lane meets its halt first. A lane asks its
/// overseer only through lane mail; a subagent's call is refused without
/// the commands, since lane mail is the lead's.
pub(super) fn question_tool_check(
    turn: &mut Turn,
    vars: &Vars,
    lane: &Lane,
    payload: &Payload,
) -> Flow {
    let Some(item) = &lane.item else {
        return Ok(());
    };
    if !QUESTION_TOOLS.contains(&payload.tool.as_str()) || !lane.launched(turn)? {
        return Ok(());
    }
    let route = (turn.caller != Caller::Subagent).then(|| routes(lane, vars, item).ask);
    let said = Said::QuestionTool {
        tool: payload.tool.clone(),
        route,
    };
    Err(turn.refuse(said, ""))
}

/// The idle judge: a lane lead's turn end that reported nothing since the
/// last judged one is held once. A report is an ask or a notice the lane
/// sent, counted against the record, or a status file update; a halt
/// standing passes; a handoff record ends the run before this judge. A turn
/// end this judge already held, or any continued one on Pi, whose carrier
/// runs no further request after a continued turn, tells the overseer
/// through the lane's own mailbox instead and ends. A gap in the reader,
/// the listing or the record passes the turn end unjudged, since nothing
/// the lane does at its turn end repairs its mailbox.
pub(super) fn idle_check(
    turn: &mut Turn,
    vars: &Vars,
    arm: &Arm,
    lane: &Lane,
    continued: bool,
) -> Flow {
    let Some(item) = &lane.item else {
        return Ok(());
    };
    if *arm != Arm::Stop || turn.caller != Caller::Lead || !lane.launched(turn)? {
        return Ok(());
    }
    let Ok(reader) = mail_reader(lane, vars) else {
        return Ok(());
    };
    let mailbox = Mailbox::new(reader);
    let events = match mailbox.events_of(item, &lane.root) {
        Ok(events) => events,
        Err(refusal @ Refusal::Reply { .. }) => {
            turn.note(&Said::EventsEnvelope, &cause(&refusal));
            return Ok(());
        }
        Err(refusal) => {
            turn.note(&Said::Events(status(&refusal)), &cause(&refusal));
            return Ok(());
        }
    };
    let sent = events
        .iter()
        .filter(|e| e.mailbox.as_deref() == Some("to-overseer"))
        .filter(|e| matches!(e.kind(), "ask" | "notice"))
        .count();
    let halted = events
        .iter()
        .rfind(|e| e.mailbox.as_deref() == Some("to-lane") && e.kind() == "directive")
        .is_some_and(|e| e.halt == Some(true));
    let status_file = lane.root.join("tmp").join(format!("lane-status-{item}.md"));
    let record = Record {
        path: lane.mail_root.join(item).join("sent-count"),
        status: status_state(turn, &status_file),
    };
    let Some(recorded) = record.read() else {
        turn.note(&Said::IdleRecord(record.path.clone()), "");
        record.write(turn, Said::IdleUnrecorded, sent, false);
        return Ok(());
    };
    // A count other than the recorded one is a send since the last judged
    // turn end; a smaller one is a mailbox replaced under the record. A
    // status file removed or unreadable is no report.
    let reported = sent.to_string() != recorded.count
        || record
            .status
            .as_ref()
            .is_some_and(|state| Some(state) != recorded.status.as_ref());
    if reported {
        record.write(turn, Said::IdleUnrecorded, sent, false);
        return Ok(());
    }
    if halted {
        if recorded.held {
            record.write(turn, Said::IdleUnrecorded, sent, false);
        }
        return Ok(());
    }
    // The flag says a stop hook's refusal continued this turn, not whose:
    // the recorded hold says it was this judge's. A turn another hook
    // continued is held as a fresh one, and the hold bounds the loop at
    // one more turn.
    if continued && (recorded.held || turn.harness == Harness::Pi) {
        idle_notice(turn, &mailbox, lane, item, &record, sent);
        return Ok(());
    }
    if !record.write(turn, Said::IdleHoldUnrecorded, sent, true) {
        return Ok(());
    }
    let said = Said::Idle {
        item: item.clone(),
        routes: Box::new(routes(lane, vars, item)),
        status_file,
    };
    Err(turn.refuse(said, ""))
}

/// The overseer told through the lane's own mailbox, as a notice from the
/// lane, that a continued turn reported nothing; it lands in the lane's
/// outbound box, so the record counts it.
fn idle_notice(
    turn: &mut Turn,
    mailbox: &Mailbox,
    lane: &Lane,
    item: &str,
    record: &Record,
    sent: usize,
) {
    let text = Said::LaneIdle(item.to_owned()).text("");
    let noticed = match Scratch::holding(&text) {
        Ok(scratch) => mailbox.notice(item, &lane.root, &scratch.0, None),
        Err(cause) => {
            turn.note(&Said::IdleNoticeUnsent("unwritten".to_owned()), &cause);
            return;
        }
    };
    let count = match noticed {
        Ok(Noticed::Sent { .. }) => sent + 1,
        // The same notice already stood there, counted in `sent`.
        Ok(Noticed::Repeated { .. }) => sent,
        Err(refusal) => {
            turn.note(&Said::IdleNoticeUnsent(status(&refusal)), &cause(&refusal));
            return;
        }
    };
    record.write(turn, Said::IdleNoticeUnrecorded, count, false);
    turn.note(&Said::IdleNotice(item.to_owned()), "");
}

/// The lane's last judged turn end: the count of asks and notices it had
/// sent, whether this judge held it, and the status file's state then,
/// one line `COUNT[ held][ status=STATE]` in the lane's mailbox directory.
struct Record {
    path: PathBuf,
    /// The status file's state now; `None` where it stands nowhere or
    /// could not be read.
    status: Option<String>,
}

/// What a [`Record`] holds.
struct Recorded {
    count: String,
    held: bool,
    status: Option<String>,
}

impl Record {
    /// The record, a count of none where none stands; `None` where what
    /// stands is no plain file holding the line's form.
    fn read(&self) -> Option<Recorded> {
        let Ok(meta) = std::fs::symlink_metadata(&self.path) else {
            return Some(Recorded {
                count: "0".to_owned(),
                held: false,
                status: None,
            });
        };
        if !meta.is_file() {
            return None;
        }
        let text = std::fs::read_to_string(&self.path).ok()?;
        let line = text.lines().next().unwrap_or_default();
        let mut words = line.split(' ').filter(|word| !word.is_empty());
        let count = words.next().unwrap_or_default().to_owned();
        let mut held = false;
        let mut status = None;
        for word in words {
            match word.strip_prefix("status=") {
                Some(state) if status.is_none() && is_state(state) => {
                    status = Some(state.to_owned());
                }
                None if word == "held" && !held && status.is_none() => held = true,
                _ => return None,
            }
        }
        whole_number(&count).then_some(Recorded {
            count,
            held,
            status,
        })
    }

    /// Write `count`, the hold where `held` and the status state, beside
    /// the record and renamed over it, so a reader never meets a half
    /// written count. What stands there in another form than a plain file
    /// is left, and `said` reports it, as it reports a write that failed.
    #[allow(
        clippy::disallowed_methods,
        reason = "the idle judge's one record, the lane's sent count in its own mailbox directory, which no workflow record holds"
    )]
    fn write(&self, turn: &mut Turn, said: fn(PathBuf) -> Said, count: usize, held: bool) -> bool {
        if std::fs::symlink_metadata(&self.path).is_ok_and(|meta| !meta.is_file()) {
            turn.note(&said(self.path.clone()), "");
            return false;
        }
        let mut line = count.to_string();
        if held {
            line.push_str(" held");
        }
        if let Some(state) = &self.status {
            line.push_str(&format!(" status={state}"));
        }
        line.push('\n');
        let mut tmp = self.path.clone().into_os_string();
        tmp.push(format!(".{}", std::process::id()));
        let tmp = PathBuf::from(tmp);
        let written = std::fs::write(&tmp, &line).and_then(|()| std::fs::rename(&tmp, &self.path));
        if let Err(e) = written {
            let _ = std::fs::remove_file(&tmp);
            turn.note(&said(self.path.clone()), &e.to_string());
            return false;
        }
        true
    }
}

/// The status file's state: its device, inode, size and modification time
/// to the nanosecond, so a rewrite within the same second and a replacement
/// both read as an update. A link or anything but a plain file is reported
/// and read as no state, as is one whose metadata cannot be read.
fn status_state(turn: &mut Turn, file: &Path) -> Option<String> {
    match std::fs::symlink_metadata(file) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            turn.note(&Said::IdleStatus(file.to_path_buf()), &e.to_string());
            None
        }
        Ok(meta) if !meta.is_file() => {
            turn.note(
                &Said::IdleStatus(file.to_path_buf()),
                "The lane status file must be a regular file, with no symbolic link at the file itself.",
            );
            None
        }
        Ok(meta) => Some(format!(
            "{}+{}+{}+{}+{}",
            meta.dev(),
            meta.ino(),
            meta.size(),
            meta.mtime(),
            meta.mtime_nsec()
        )),
    }
}

/// A status state as the record holds it: one word, only ever compared.
fn is_state(state: &str) -> bool {
    !state.is_empty()
        && state
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'/' | b'='))
}

/// Digits with no leading zero, or `0`.
fn whole_number(text: &str) -> bool {
    !text.is_empty()
        && text.bytes().all(|b| b.is_ascii_digit())
        && (text == "0" || !text.starts_with('0'))
}

/// The mailbox reader the settings name (`LANE_MAIL_CLI`, else the mailbox
/// package of the lane's own install), where it is an executable.
fn mail_reader(lane: &Lane, vars: &Vars) -> Result<PathBuf, (Said, String)> {
    let unsettled = |e: crate::Error| (Said::ReaderUnsettled, e.to_string());
    let roots = agent_runtime::settings::roots(&lane.root).map_err(|e| unsettled(e.into()))?;
    let environment: Vec<_> = std::env::vars_os().collect();
    let flags = Flags {
        state_dir: None,
        private_env: vars.private_env,
    };
    let cli = settings::load(&roots, &environment, &flags)
        .map_err(unsettled)?
        .lane_mail_cli;
    let executable = std::fs::metadata(&cli)
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0);
    if !executable {
        return Err((Said::Reader(cli), String::new()));
    }
    Ok(cli)
}

/// The plain read that acknowledges a halt, as the lead runs it.
fn read_command(reader: &Path, item: &str, root: &Path) -> String {
    format!(
        "{} inbox --item {} --root {}",
        shell_quoted(reader),
        shell_quoted(Path::new(item)),
        shell_quoted(root)
    )
}

/// The routes a refusal names, through the lane's reader where it
/// resolves and by the verb's name where it does not: the route is the
/// rule, and the gap in the install has its own line at the mail check.
fn routes(lane: &Lane, vars: &Vars, item: &str) -> Routes {
    let asker = mail_reader(lane, vars).unwrap_or_else(|_| PathBuf::from("lane-mail"));
    let (asker, item, root) = (
        shell_quoted(&asker),
        shell_quoted(Path::new(item)),
        shell_quoted(&lane.root),
    );
    Routes {
        ask: format!(
            "  {asker} ask --item {item} --root {root} --file [PATH]\n  {asker} wait --item {item} --root {root} --id [MSGID]"
        ),
        inbox: format!("  {asker} inbox --item {item} --root {root}"),
        notice: format!("  {asker} notice --item {item} --root {root} --file [PATH]"),
    }
}

/// The context answer for `text` under `event`, with the cursor move made
/// once it is written; one that cannot be written is refused as the arm
/// refuses, so nothing meant to be handed over passes as handed.
fn hand_over(
    turn: &mut Turn,
    event: &str,
    text: &str,
    kendex_ack: Option<&[String]>,
    ack: Option<Box<Ack>>,
) -> Answer {
    Answer {
        stdout: answer::context(turn.harness, event, text, kendex_ack),
        stderr: std::mem::take(&mut turn.stderr),
        code: 0,
        ack,
        unwritten: Some(answer::refusal(turn.harness, turn.arm.as_ref(), "").1),
    }
}

/// The exit status a refusal of the reader names, or the word for a run
/// that gave none.
fn status(refusal: &Refusal) -> String {
    match refusal {
        Refusal::Exit {
            status: Some(code), ..
        } => code.to_string(),
        Refusal::Exit { status: None, .. } => "signal".to_owned(),
        Refusal::NotStarted { .. } => "unstarted".to_owned(),
        Refusal::Unanswered { .. } => "unanswered".to_owned(),
        Refusal::Reply { cause, .. } => format!("reply-{cause}"),
    }
}

/// The reader's own words for a refusal, for the line under the key.
fn cause(refusal: &Refusal) -> String {
    match refusal {
        Refusal::Exit { stderr, .. } => stderr.clone(),
        Refusal::NotStarted { cause, .. } | Refusal::Unanswered { cause, .. } => cause.clone(),
        Refusal::Reply { line, .. } => line.clone(),
    }
}

/// The idle notice's text as the file the mailbox's `notice` reads,
/// removed when the send returns.
struct Scratch(PathBuf);

impl Scratch {
    #[allow(
        clippy::disallowed_methods,
        reason = "the idle notice's text, written once for the mailbox's own notice to read; removed when the send returns"
    )]
    fn holding(text: &str) -> Result<Scratch, String> {
        let path =
            std::env::temp_dir().join(format!("lane-mail-check-idle.{}", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let mut file = std::fs::File::create_new(&path).map_err(|e| e.to_string())?;
        std::io::Write::write_all(&mut file, format!("{text}\n").as_bytes())
            .map_err(|e| e.to_string())?;
        Ok(Scratch(path))
    }
}

impl Drop for Scratch {
    #[allow(
        clippy::disallowed_methods,
        reason = "the idle notice's text removed once the send returns"
    )]
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
