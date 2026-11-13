//! The handoff marks a launched lane's lead is judged on: the context mark
//! at its turn end, and the context mark less the attached-agent reserve at
//! an attached launch, the bound overseer's launch beside it. A lane whose handoff record already stands is
//! handing itself off and is never held here. The reading is the one
//! agent-runtime's reader takes of the session's own file, recorded to the
//! lane's mailbox for the watch and the report, and judged by the one judge
//! of a reading, `watch::overseer::lane_marks`, under this checkout's
//! settings.

use std::cell::Cell;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use agent_runtime::clock;
use agent_runtime::context::{self, Usage};
use serde_json::{Value, json};

use super::agents::{self, Deadline, Roster, State};
use super::answer::{Harness, Said};
use super::controller;
use super::identity::{Lane, shell_quoted};
use super::payload::{Caller, Leads, Payload};
use super::{Answer, Arm, Flow, Turn, Vars};
use crate::marker::CONTEXT_RECORD;
use crate::ops::store::handoff_standing;
use crate::settings::{self, Flags, HANDOFF_AGENT_RESERVE_KEY, Settings};
use crate::watch::context::ContextRecord;
use crate::watch::mail::overseer_dir;
use crate::watch::overseer::{lane_marks, scripts_dir};

/// The attached-launch reserve where the setting names none.
const DEFAULT_RESERVE: u64 = 150_000;

const AGENT_INSTRUCTION: &str = "Wait for each attached subagent this session launched to return in this turn before normal succession. Use the harness wait or result tool; another Stop refusal alone is not a wait. If the session cannot wait, name each unfinished agent, its known output path, and any unknown state in the existing handoff. The successor reads available agent output before repeating its task.";

const DETACHED_ROUTE: &str = "lane-mail-check: detached-route=orch-job-runner\nUse the orch job runner described in waiter-launch.md, Launch, or a separate session for work that must survive this session.";

/// What one read of the session's own file took.
pub(super) enum Reading {
    Measured {
        tokens: u64,
        window: Option<u64>,
        model: String,
    },
    /// A usage line stands that the adapter does not read.
    Unread,
    /// No reading, with the gap that names why where one does.
    None(Option<&'static str>),
    /// Copilot flagged this session's automatic compaction: past the mark
    /// whatever a reading says.
    Compacted,
}

/// Whose marks a judgement reads: the seat decides where the reading is
/// recorded and the hand-over a refusal names.
pub(super) enum Seat {
    /// A launched lane's lead, recorded under its item's mailbox.
    Lane,
    /// The fleet's controller, its records keyed `<server> <pane>`, its
    /// transcript bound under its launch home `home`.
    Overseer {
        key: String,
        pane: String,
        home: String,
    },
    /// A managed Jarvis session: its own succession clears a reached mark,
    /// and any other gap is said and passed, since retiring the session
    /// cannot clear it. Its reading is recorded only where the fleet record
    /// binds it, under `key`, in the overseer mailbox.
    Jarvis {
        key: Option<String>,
        home: PathBuf,
        /// The installed Jarvis package's scripts directory.
        scripts: PathBuf,
    },
}

/// One session's judgement: its item, its settings, the state file its
/// handoff is recorded in and the mailbox its reading is recorded in.
pub(super) struct Judge<'a> {
    lane: &'a Lane,
    item: &'a str,
    vars: &'a Vars,
    payload: &'a Payload,
    pub(super) settings: Settings,
    /// The state file the handoff read named.
    file: PathBuf,
    pub(super) mailbox: PathBuf,
    seat: Seat,
    /// The capacity source of the reading taken, where it names one; the
    /// handoff record's context carries it.
    source: Cell<Option<&'static str>>,
    /// Whether the reading found a flagged automatic compaction.
    compacted: Cell<bool>,
}

/// Where a gate leaves a judgement: judged; no lane a mark is judged for;
/// or a lane whose handoff record stands, which nothing here may hold.
enum Gate<'a> {
    Judge(Box<Judge<'a>>),
    NoMark,
    Stands,
}

/// The lane's own context mark at its turn end. A session that is no
/// launched lane's lead, and a lane whose handoff record stands, meets no
/// mark here; the overseer's marks and the account mark are judged
/// elsewhere.
pub(super) fn handoff_check(
    turn: &mut Turn,
    arm: &Arm,
    lane: &Lane,
    vars: &Vars,
    payload: &Payload,
) -> Flow {
    if *arm != Arm::Stop || turn.caller != Caller::Lead {
        return Ok(());
    }
    if lane.item.is_none() {
        return controller::turn_end(turn, lane, vars, payload);
    }
    let judge = match mark_gate(turn, lane, vars, payload)? {
        Gate::Judge(judge) => judge,
        Gate::NoMark => return Ok(()),
        Gate::Stands => return Err(turn.pass()),
    };
    let pct = judge.context_share(turn)?;
    let mailbox = judge.mailbox.clone();
    match judge.read_and_record(turn, &mailbox)? {
        Reading::Measured {
            tokens,
            window,
            model,
        } => {
            let marks = judge.judged_marks(turn, tokens, window, None)?;
            match marks["context"].as_str() {
                Some("due") => {
                    let instruction =
                        judge.handoff_instruction(turn, marks["context_decision"].clone())?;
                    let said = Said::Context {
                        tokens,
                        window,
                        mark: pct,
                        instruction,
                    };
                    return Err(turn.refuse(said, ""));
                }
                Some("room") => {}
                _ => {
                    let named = if model.is_empty() {
                        harness_word(turn.harness).to_owned()
                    } else {
                        model
                    };
                    turn.note(&Said::WindowUnread(named), "");
                }
            }
        }
        Reading::Unread => turn.note(&Said::UsageUnread(payload.transcript.clone()), ""),
        Reading::None(_) => {}
        Reading::Compacted => {
            let instruction = judge.handoff_instruction(turn, Value::Null)?;
            return Err(turn.refuse(Said::Compacted { instruction }, ""));
        }
    }
    Ok(())
}

/// The harness and tool names an attached launch is made with. Codex
/// writes a tool name as its canonical name or a configured namespace
/// before it, so its launches match by suffix.
fn attached_launch(harness: Harness, tool: &str) -> bool {
    match harness {
        Harness::Claude => tool == "Agent",
        Harness::Codex => tool.ends_with("spawn_agent") || tool.ends_with("followup_task"),
        Harness::Pi => matches!(tool, "subagent" | "delegate_subagent"),
        Harness::Copilot => matches!(tool, "task" | "Agent" | "Task"),
        Harness::Unlisted => false,
    }
}

/// An attached launch by a launched lane's lead or the bound overseer:
/// refused at the context mark, and at the mark less the reserve while an
/// attached agent may still be out. Only a launch tool pays for this read;
/// wait, result and handoff tools stay usable.
pub(super) fn attached_launch_check(
    turn: &mut Turn,
    lane: &Lane,
    vars: &Vars,
    payload: &Payload,
) -> Flow {
    if turn.caller != Caller::Lead || !attached_launch(turn.harness, &payload.tool) {
        return Ok(());
    }
    let judge = match mark_gate(turn, lane, vars, payload)? {
        Gate::Judge(judge) => judge,
        Gate::NoMark | Gate::Stands => return Ok(()),
    };
    judge.context_share(turn)?;
    let reserve = judge.agent_reserve(turn)?;
    let (tokens, window) = match judge.launch_reading(turn)? {
        Ok(reading) => reading,
        Err(gap) => return Err(judge.refuse_input(turn, gap)),
    };
    let marks = judge.judged_marks(turn, tokens, window, Some(reserve))?;
    let tool = &payload.tool;
    match marks["context"].as_str() {
        Some("due") => {
            let instruction = judge.handoff_instruction(turn, marks["context_decision"].clone())?;
            let said = Said::AgentLaunch {
                value: format!("{tool} tokens={tokens}"),
                instruction,
            };
            return Err(turn.refuse(said, ""));
        }
        Some("room") => {}
        _ => return Err(judge.refuse_input(turn, "context-unmeasured")),
    }
    let reserved = &marks["reserve"];
    match reserved["context"].as_str() {
        Some("room") => return Ok(()),
        Some("due") => {}
        _ => return Err(judge.refuse_input(turn, "context-unmeasured")),
    }
    let Roster { state, rows } = agents::roster(turn.harness, payload, &turn.deadline);
    let value = format!("{tool} tokens={tokens} reserve={reserve}");
    let said = match state {
        State::None => return Ok(()),
        State::Out => Said::AgentReserve {
            value,
            rows,
            codex: turn.harness == Harness::Codex,
        },
        // No wait clears a roster that cannot be read: a lane is named its
        // handoff record, which stands at any reading, and the overseer no
        // succession, which refuses below the plain mark.
        State::Unknown => Said::AgentUnobserved {
            value,
            rows,
            instruction: match judge.seat {
                Seat::Overseer { .. } => String::new(),
                Seat::Lane | Seat::Jarvis { .. } => {
                    judge.handoff_instruction(turn, reserved["context_decision"].clone())?
                }
            },
        },
    };
    Err(turn.refuse(said, ""))
}

/// The settings and the standing handoff a launched lane's marks are judged
/// under, or at an attached launch the bound overseer's, under the fleet
/// item's. A lane no launch recorded, and any other session naming no lane
/// item, has no mark here. Settings that do not load and a handoff that
/// cannot be read pass a turn end with the gap reported, and refuse an
/// attached launch on that input; a lane's standing record passes both, the
/// overseer's only where it names this session.
fn mark_gate<'a>(
    turn: &mut Turn,
    lane: &'a Lane,
    vars: &'a Vars,
    payload: &'a Payload,
) -> Flow<Gate<'a>> {
    let halt = turn.arm == Some(Arm::Halt);
    let (item, seat) = match lane.item.as_deref() {
        Some(item) => {
            if !lane.launched(turn)? {
                return Ok(Gate::NoMark);
            }
            (item, Seat::Lane)
        }
        None => match controller::launch_seat(turn) {
            Some(seat) => (OVERSEER_ITEM, seat),
            None => return Ok(Gate::NoMark),
        },
    };
    let unanswered = |turn: &mut Turn, value: &str, cause: &str| {
        if halt {
            let instruction = format!("{DETACHED_ROUTE}\n{AGENT_INSTRUCTION}");
            let said = Said::AgentInput {
                value: value.to_owned(),
                instruction,
            };
            return turn.refuse(said, cause);
        }
        turn.note(&Said::HandoffUnanswered, cause);
        turn.pass()
    };
    let settings = match marks_settings(&lane.root, vars.private_env) {
        Ok(settings) => settings,
        Err(cause) => return Err(unanswered(turn, "unanswered", &cause)),
    };
    let (root, mailbox) = match &seat {
        Seat::Lane => (Some(lane.root.as_path()), lane.mail_root.join(item)),
        Seat::Overseer { .. } | Seat::Jarvis { .. } => (None, overseer_dir(&settings.roots.common)),
    };
    let standing = match handoff_standing(&settings.state_dir, item, root) {
        Ok(standing) => standing,
        Err(e) => return Err(unanswered(turn, "unanswered", &e.to_string())),
    };
    let judge = Judge {
        lane,
        item,
        vars,
        payload,
        settings,
        file: PathBuf::from(standing["file"].as_str().unwrap_or_default()),
        mailbox,
        seat,
        source: Cell::new(None),
        compacted: Cell::new(false),
    };
    match standing["standing"].as_str() {
        Some("stands") if judge.handoff_ends(&standing["record"]) => Ok(Gate::Stands),
        Some("stands" | "none") => Ok(Gate::Judge(Box::new(judge))),
        _ if halt => Err(judge.refuse_input(turn, "unreadable")),
        _ => {
            let file = judge.file.display().to_string();
            turn.note(&Said::HandoffUnreadable(file), "");
            Err(turn.pass())
        }
    }
}

/// This checkout's settings, read from the lane's root by the load every
/// verb takes, with the caller's environment and the command line's word on
/// the private env file.
pub(super) fn marks_settings(root: &Path, private_env: bool) -> Result<Settings, String> {
    let roots = agent_runtime::settings::roots(root).map_err(|e| e.to_string())?;
    let environment: Vec<(OsString, OsString)> = std::env::vars_os().collect();
    let flags = Flags {
        state_dir: None,
        private_env,
    };
    settings::load(&roots, &environment, &flags).map_err(|e| e.to_string())
}

/// The wall time a reading is recorded at, which the watch's stale rule
/// and the report compare with the session's rows.
#[allow(
    clippy::disallowed_methods,
    reason = "the context record's `at`, the wall time it was written, which its readers compare with wall-clock rows"
)]
pub(super) fn record_stamp() -> String {
    clock::now()
}

pub(super) fn harness_word(harness: Harness) -> &'static str {
    match harness {
        Harness::Claude => "claude",
        Harness::Codex => "codex",
        Harness::Pi => "pi",
        Harness::Copilot => "copilot",
        Harness::Unlisted => "",
    }
}

impl<'a> Judge<'a> {
    /// The fleet controller's judgement under `settings`: its reading
    /// recorded in `mailbox` under its key, its handoff the fleet item's in
    /// `file`.
    pub(super) fn controller(
        lane: &'a Lane,
        vars: &'a Vars,
        payload: &'a Payload,
        settings: Settings,
        file: PathBuf,
        mailbox: PathBuf,
        seat: Seat,
    ) -> Judge<'a> {
        Judge {
            lane,
            item: OVERSEER_ITEM,
            vars,
            payload,
            settings,
            file,
            mailbox,
            seat,
            source: Cell::new(None),
            compacted: Cell::new(false),
        }
    }

    /// The key the reading is recorded under: the controller's alone.
    fn pane_key(&self) -> Option<String> {
        match &self.seat {
            Seat::Lane => None,
            Seat::Overseer { key, .. } => Some(key.clone()),
            Seat::Jarvis { key, .. } => key.clone(),
        }
    }

    /// Whether a standing handoff ends this judgement: a lane's always, the
    /// overseer's only where it names this session, since a predecessor's
    /// record clears no successor.
    fn handoff_ends(&self, record: &Value) -> bool {
        match &self.seat {
            Seat::Overseer { key, .. } => {
                controller::handoff_mine(record, &self.payload.session, key)
            }
            Seat::Lane | Seat::Jarvis { .. } => true,
        }
    }

    /// The reading an attached launch is judged on, or the input that left
    /// it unjudged: the overseer's is its turn end's own read.
    fn launch_reading(&self, turn: &mut Turn) -> Flow<Result<(u64, Option<u64>), &'static str>> {
        if let Seat::Overseer { key, home, .. } = &self.seat {
            return controller::launch_read(turn, self, self.payload, home, key);
        }
        Ok(match self.read_and_record(turn, &self.mailbox)? {
            Reading::Measured { tokens, window, .. } => Ok((tokens, window)),
            Reading::Unread => Err("usage-unread"),
            Reading::None(gap) => Err(gap.unwrap_or("usage-absent")),
            Reading::Compacted => Err("usage-absent"),
        })
    }

    /// Whether the reading is recorded: a Jarvis session the fleet record
    /// does not bind keeps no record, since no watch reads one.
    fn records(&self) -> bool {
        match &self.seat {
            Seat::Lane | Seat::Overseer { .. } => true,
            Seat::Jarvis { key, .. } => key.is_some(),
        }
    }

    /// A refusal of the judgement: a Jarvis session is told the gap and
    /// passed, since its succession cannot clear an input it could not
    /// read.
    pub(super) fn refuse(&self, turn: &mut Turn, said: Said, cause: &str) -> Answer {
        match &self.seat {
            Seat::Jarvis { .. } => {
                turn.note(&Said::JarvisUnjudged(Box::new(said)), cause);
                turn.pass()
            }
            Seat::Lane | Seat::Overseer { .. } => turn.refuse(said, cause),
        }
    }

    /// The context mark's share, refused on a value outside its form.
    pub(super) fn context_share(&self, turn: &mut Turn) -> Flow<u32> {
        match &self.settings.marks.context_pct.read {
            Ok(pct) => Ok(*pct),
            Err((key, value)) => {
                let instruction = self.handoff_instruction(turn, Value::Null)?;
                let said = Said::SettingRange {
                    value: format!("{key}={value}"),
                    instruction,
                };
                Err(self.refuse(turn, said, ""))
            }
        }
    }

    /// The attached-launch reserve: the setting's whole number, the
    /// default where unset, refused on any other form. A figure past what
    /// a count holds leaves no room below the mark, as any reserve at the
    /// absolute mark does.
    fn agent_reserve(&self, turn: &mut Turn) -> Flow<u64> {
        let Some(text) = self.settings.marks.agent_reserve.as_deref() else {
            return Ok(DEFAULT_RESERVE);
        };
        let whole =
            text.bytes().all(|b| b.is_ascii_digit()) && (text == "0" || !text.starts_with('0'));
        if !text.is_empty() && whole {
            return Ok(text.parse().unwrap_or(u64::MAX));
        }
        let instruction = self.handoff_instruction(turn, Value::Null)?;
        let said = Said::SettingRange {
            value: format!("{HANDOFF_AGENT_RESERVE_KEY}={text}"),
            instruction,
        };
        Err(self.refuse(turn, said, ""))
    }

    /// The one judge's answer on a reading, the reserve's beside the plain
    /// one where an attached launch names it.
    pub(super) fn judged_marks(
        &self,
        turn: &mut Turn,
        tokens: u64,
        window: Option<u64>,
        reserve: Option<u64>,
    ) -> Flow<Value> {
        let reading = format!(
            "{tokens}:{}",
            window
                .filter(|w| *w > 0)
                .map(|w| w.to_string())
                .unwrap_or_default()
        );
        match lane_marks(&self.settings, &reading, reserve) {
            Ok(marks) => Ok(marks),
            Err(e) => {
                let instruction = self.handoff_instruction(turn, Value::Null)?;
                let said = Said::SettingRange {
                    value: e.to_string(),
                    instruction,
                };
                Err(self.refuse(turn, said, ""))
            }
        }
    }

    /// An attached launch refused on an input it could not be judged on.
    fn refuse_input(&self, turn: &mut Turn, value: &str) -> Answer {
        match self.handoff_instruction(turn, Value::Null) {
            Ok(instruction) => {
                let said = Said::AgentInput {
                    value: value.to_owned(),
                    instruction,
                };
                self.refuse(turn, said, "")
            }
            Err(answer) => answer,
        }
    }

    /// This session's context through agent-runtime's reader for its
    /// harness, recorded in `mailbox` for the report and the watch. A
    /// transcript named and unreadable is refused, since the handoff record
    /// is what clears it; a record that cannot be written is reported and
    /// the reading still judged.
    pub(super) fn read_and_record(&self, turn: &mut Turn, mailbox: &Path) -> Flow<Reading> {
        let transcript = self.payload.transcript.as_str();
        let harness = turn.harness;
        if harness == Harness::Unlisted {
            if !transcript.is_empty() {
                turn.note(&Said::HarnessUnlisted(turn.hook_dir.clone()), "");
            }
            return Ok(Reading::None(None));
        }
        if harness == Harness::Copilot {
            return self.copilot_reading(turn, mailbox);
        }
        if transcript.is_empty() {
            return Ok(Reading::None(Some("transcript-unnamed")));
        }
        let path = Path::new(transcript);
        let readable = std::fs::metadata(path).is_ok_and(|meta| meta.is_file())
            && std::fs::File::open(path).is_ok();
        if !readable {
            let said = Said::TranscriptUnreadable {
                transcript: transcript.to_owned(),
                instruction: self.handoff_instruction(turn, Value::Null)?,
            };
            return Err(self.refuse(turn, said, ""));
        }
        let read = match harness {
            Harness::Claude => {
                let off = context::claude_compaction_off();
                context::read_file(path, |text| context::claude(text, off))
            }
            Harness::Codex => {
                let overrides = std::env::var("ORCH_COMPACTION_OVERRIDES").ok();
                context::read_file(path, |text| context::codex(text, overrides.as_deref()))
            }
            Harness::Pi | Harness::Copilot | Harness::Unlisted => {
                let off = match context::pi_compaction_on(
                    &self.pi_user_settings(),
                    &self.pi_project_settings(),
                ) {
                    Ok(on) => !on,
                    Err(unread) => {
                        let cause =
                            format!("pi-settings={}\n{}", unread.file.display(), unread.cause);
                        turn.note(&Said::CompactionUnread("pi"), &cause);
                        false
                    }
                };
                let deadline = turn.deadline;
                context::read_file(path, |text| {
                    context::pi(text, off, |model| {
                        self.pi_reading_window(mailbox, model, &deadline)
                    })
                })
            }
        };
        self.recorded(turn, mailbox, read)
    }

    /// A reading judged from what one read took, recorded in `mailbox`
    /// under the capacity source the reading names. A read refused on a
    /// line it could not take is refused, since the handoff record is what
    /// clears it.
    fn recorded(
        &self,
        turn: &mut Turn,
        mailbox: &Path,
        read: Result<Usage, String>,
    ) -> Flow<Reading> {
        let transcript = self.payload.transcript.as_str();
        let (tokens, window, model) = match read {
            Ok(Usage::Measured {
                tokens,
                window,
                model,
            }) => (tokens, window, model),
            Ok(Usage::Unread) => return Ok(Reading::Unread),
            Ok(Usage::Absent) => return Ok(Reading::None(Some("usage-absent"))),
            Err(cause) => {
                let said = Said::TranscriptUnread {
                    transcript: transcript.to_owned(),
                    instruction: self.handoff_instruction(turn, Value::Null)?,
                };
                return Err(self.refuse(turn, said, &cause));
            }
        };
        let nul = |text: &str| (!text.is_empty()).then(|| text.to_owned());
        let record = ContextRecord {
            harness: Some(harness_word(turn.harness).to_owned()),
            tokens: Some(tokens),
            window,
            model: nul(&model),
            capacity_source: self.source.get().map(str::to_owned),
            session_id: nul(&self.payload.session),
            pane_key: self.pane_key(),
            gap: None,
            at: Some(record_stamp()),
        };
        if !self.records() {
            return Ok(Reading::Measured {
                tokens,
                window,
                model,
            });
        }
        if let Err(cause) = record.write_to(mailbox) {
            turn.note(
                &Said::ContextUnrecorded(mailbox.join(CONTEXT_RECORD)),
                &cause,
            );
        }
        Ok(Reading::Measured {
            tokens,
            window,
            model,
        })
    }

    /// Pi's user directory: `PI_CODING_AGENT_DIR`, else the home's
    /// `.pi/agent`.
    fn pi_agent_dir(&self) -> PathBuf {
        match &self.vars.pi_dir {
            Some(dir) => dir.clone(),
            None => {
                let home = std::env::var_os("LANES_HOME")
                    .filter(|h| !h.is_empty())
                    .unwrap_or_else(|| OsString::from(&self.vars.home));
                PathBuf::from(home).join(".pi").join("agent")
            }
        }
    }

    fn pi_user_settings(&self) -> PathBuf {
        self.pi_agent_dir().join("settings.json")
    }

    /// Pi's project settings file, in the directory the session started in.
    fn pi_project_settings(&self) -> PathBuf {
        let dir = self.vars.project_dir.as_ref().unwrap_or(&self.vars.pwd);
        dir.join(".pi").join("settings.json")
    }

    /// The window a Pi reading on `model` takes with compaction off: the
    /// one the payload named, else the one this mailbox's record holds for
    /// the same session and model, else the one Pi's own model registry
    /// holds, read within what is left of the turn end's deadline.
    fn pi_reading_window(&self, mailbox: &Path, model: &str, deadline: &Deadline) -> Option<u64> {
        if let Some(window) = self.payload.context_window {
            return Some(window);
        }
        self.pi_record_window(mailbox, model)
            .or_else(|| registry_window(model, &self.pi_agent_dir(), deadline))
    }

    /// The window this mailbox's record holds for the payload's session and
    /// `model`.
    fn pi_record_window(&self, mailbox: &Path, model: &str) -> Option<u64> {
        let session = self.payload.session.as_str();
        if session.is_empty() {
            return None;
        }
        let text = std::fs::read_to_string(mailbox.join(CONTEXT_RECORD)).ok()?;
        let record = ContextRecord::parse(&text).ok()?;
        (record.harness.as_deref() == Some("pi")
            && record.session_id.as_deref() == Some(session)
            && record.model.as_deref().unwrap_or_default() == model)
            .then_some(record.window)
            .flatten()
    }

    /// A Copilot lead's context at its turn end, which no transcript of
    /// Copilot's holds. A flagged automatic compaction comes first: past the
    /// mark whatever a reading says. Then the reading the context extension
    /// handed over and the usage arm recorded for this session, waited for
    /// while its pending marker stands; then the status-line record, read
    /// beside either for its stop cause and for the reading only where the
    /// extension has none. A flag or a record that stands and cannot be
    /// read is refused, since the handoff record clears it; a status-line
    /// record that does not answer leaves the context unmeasured, never
    /// read as room.
    fn copilot_reading(&self, turn: &mut Turn, mailbox: &Path) -> Flow<Reading> {
        let session = self.payload.session.as_str();
        match compaction_flagged(mailbox, session) {
            Ok(true) => {
                self.compacted.set(true);
                return Ok(Reading::Compacted);
            }
            Ok(false) => {}
            Err((path, cause)) => return Err(self.refuse_record(turn, path, &cause)),
        }
        let extension = if self.reading_pending(turn) {
            Some(Reading::None(None))
        } else {
            self.extension_reading(turn, mailbox)?
        };
        let home = self.copilot_account();
        let transcript = self.payload.transcript.as_str();
        let record = match context::copilot_record(&home, session, transcript, epoch_now()) {
            Ok(record) => record,
            Err(reason) => {
                if let Some(reading) = extension {
                    return Ok(reading);
                }
                turn.note(&Said::ReadingUnrecorded(mailbox.join(CONTEXT_RECORD)), "");
                turn.note(&Said::SessionRecord(reason), "");
                return Ok(Reading::None(Some("session-record")));
            }
        };
        let granted = std::env::var("COPILOT_ALLOW_ALL").is_ok_and(|grant| grant == "true");
        if let Some(cause) = record.stop_cause(granted) {
            turn.note(&Said::StopCause(cause), "");
        }
        if let Some(reading) = extension {
            return Ok(reading);
        }
        self.source.set(Some(context::COPILOT_STATUS_LINE_SOURCE));
        self.recorded(turn, mailbox, Ok(record.usage()))
    }

    /// Whether a reading of this session is still on its way to the
    /// record: the extension's pending marker stands past the wait, said so.
    fn reading_pending(&self, turn: &mut Turn) -> bool {
        let Some(marker) = Leads::under(&self.vars.home).pending(&self.payload.session) else {
            return false;
        };
        if !pending_outlasts_wait(&marker, &turn.deadline) {
            return false;
        }
        turn.note(&Said::ReadingPending(marker), "");
        true
    }

    /// The extension's reading of this session from the mailbox's record:
    /// `None` where no record stands or it is no reading of the extension's
    /// for this session (another session's, a gap record, a status-line
    /// reading), so the status-line record is read in its place.
    fn extension_reading(&self, turn: &mut Turn, mailbox: &Path) -> Flow<Option<Reading>> {
        let path = mailbox.join(CONTEXT_RECORD);
        if std::fs::metadata(&path).is_err() {
            return Ok(None);
        }
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) => return Err(self.refuse_record(turn, path, &e.to_string())),
        };
        let Ok(record) = ContextRecord::parse(&text) else {
            let cause = "it is neither a reading nor a gap record";
            return Err(self.refuse_record(turn, path, cause));
        };
        let own = record.session_id.as_deref().unwrap_or_default() == self.payload.session;
        if !own || record.capacity_source.as_deref() != Some(context::COPILOT_EXTENSION_SOURCE) {
            return Ok(None);
        }
        self.source.set(Some(context::COPILOT_EXTENSION_SOURCE));
        Ok(Some(match record.tokens {
            Some(tokens) => Reading::Measured {
                tokens,
                window: record.window,
                model: record.model.unwrap_or_default(),
            },
            None => Reading::None(None),
        }))
    }

    /// A flag or record that stands and cannot be read, refused with the
    /// handoff that clears it.
    fn refuse_record(&self, turn: &mut Turn, path: PathBuf, cause: &str) -> Answer {
        match self.handoff_instruction(turn, Value::Null) {
            Ok(instruction) => self.refuse(turn, Said::RecordUnread { path, instruction }, cause),
            Err(answer) => answer,
        }
    }

    /// The account directory a Copilot session runs on: `COPILOT_HOME`,
    /// else the home's `.copilot`.
    fn copilot_account(&self) -> PathBuf {
        if let Some(home) = std::env::var_os("COPILOT_HOME").filter(|h| !h.is_empty()) {
            return PathBuf::from(home);
        }
        let home = std::env::var_os("LANES_HOME")
            .filter(|h| !h.is_empty())
            .unwrap_or_else(|| OsString::from(&self.vars.home));
        PathBuf::from(home).join(".copilot")
    }

    /// The commands that record this lane's handoff and tell its overseer,
    /// with the agent instruction ahead of them: at a Claude turn end the
    /// roster of attached agents still out, at an attached launch the
    /// detached route. `decision` is the reading the refusal names, which
    /// the record carries as its context.
    fn handoff_instruction(&self, turn: &mut Turn, decision: Value) -> Flow<String> {
        self.instruction(turn, decision, None)
    }

    /// [`Judge::handoff_instruction`] for a refusal a mark sent: a
    /// controller's succession walk leaves the account of an account mark,
    /// and keeps it for the context mark.
    pub(super) fn instruction(
        &self,
        turn: &mut Turn,
        decision: Value,
        mark: Option<&str>,
    ) -> Flow<String> {
        if let Seat::Jarvis { home, scripts, .. } = &self.seat {
            let package = scripts.parent().unwrap_or(scripts);
            return Ok(format!(
                "Reach a safe point. Follow Succession in {}/workflows/session.md. Replace the handoff as that workflow requires, then run:\n  {} succeed --home {}",
                package.display(),
                shell_quoted(&scripts.join("jarvis-session")),
                shell_quoted(home)
            ));
        }
        let mut agent = AGENT_INSTRUCTION.to_owned();
        if turn.arm == Some(Arm::Stop) && turn.harness == Harness::Claude {
            let roster = agents::claude_roster(self.payload, &turn.deadline);
            agent = format!("{agent}\n{}", roster.rows);
        }
        if turn.arm == Some(Arm::Halt) {
            agent = format!("{DETACHED_ROUTE}\n{agent}");
        }
        let nul = |text: &str| (!text.is_empty()).then(|| text.to_owned());
        let context = json!({
            "decision": decision,
            "source": {
                "harness": nul(harness_word(turn.harness)),
                "session_id": nul(&self.payload.session),
                "transcript": nul(&self.payload.transcript),
                "pane_key": self.pane_key(),
                "capacity_source": self.source.get(),
                "compacted": self.compacted.get(),
            },
        });
        if let Seat::Overseer { key, pane, .. } = &self.seat {
            return Ok(self.succession(&agent, &context, key, pane, mark));
        }
        let state_args = match self.file.parent() {
            Some(dir) if !self.file.as_os_str().is_empty() => {
                format!(" --state-dir {}", shell_quoted(dir))
            }
            _ => String::new(),
        };
        let workflow_state =
            shell_quoted(&scripts_dir(&self.settings.roots.project).join("workflow-state"));
        let item = shell_quoted(Path::new(self.item));
        let mut init = String::new();
        if !std::fs::metadata(&self.file).is_ok_and(|meta| meta.is_file()) {
            let branch = self.lane.branch(turn)?;
            init = if branch.is_empty() {
                format!("  {workflow_state}{state_args} init {item}\n")
            } else {
                format!(
                    "  {workflow_state}{state_args} init {item} --branch {}\n",
                    shell_quoted(Path::new(&branch))
                )
            };
        }
        let record = format!(
            r#"{{"merged":["[PR]"],"remaining":["[STEP]"],"branch":"[BRANCH]","worktree":"[WORKTREE_PATH]","open_pr":"[PR_NUMBER_OR_NULL]","traps":["[TRAP]"],"context":{context}}}"#
        );
        let word = format!("'{}'", record.replace('\'', r"'\''"));
        let reader = shell_quoted(&self.settings.lane_mail_cli);
        Ok(format!(
            "{agent}\nReach the next safe point first, a pushed head, a landed merge or a held PR; never interrupt a round or leave an unpushed tree. There, write the handoff record and send the notice, then end the session:\n{init}  {workflow_state}{state_args} set {item} handoff {word}\n  {reader} notice --item {item} --file [FILE NAMING WHAT IS LEFT]\nThis refusal repeats at every turn end until that record stands."
        ))
    }

    /// The controller's route out of a refusal: its own succession through
    /// the runtime, the successor walked for its pane, and where that
    /// refuses, the handoff record naming this session by its native id and
    /// its key, so it ends this refusal for this session and no other.
    fn succession(
        &self,
        agent: &str,
        context: &Value,
        key: &str,
        pane: &str,
        mark: Option<&str>,
    ) -> String {
        let record = json!({
            "op": "record-overseer-ledger",
            "entry": "handoff",
            "handoff_file": "[OVERSEER_HANDOFF_PATH]",
            "pane_key": key,
            "session_id": self.payload.session,
            "context": context,
        });
        let word = format!("'{}'", record.to_string().replace('\'', r"'\''"));
        let runtime = shell_quoted(&scripts_dir(&self.settings.roots.project).join("orch-runtime"));
        let root = shell_quoted(&self.lane.root);
        let predecessor = shell_quoted(Path::new(pane));
        let mark = mark
            .map(|kind| format!(" --mark {kind}"))
            .unwrap_or_default();
        format!(
            "{agent}\nReach a safe point first, with no merged event part-handled and no lane waiting on an answer only the root can give. There, rewrite the overseer handoff file and succeed this session through the orch runtime: choose the successor with\n  {runtime} successor --fleet --cwd {root} --predecessor {predecessor}{mark}\nthen ask for request-transfer with cause live, the reply's .result.successor as the successor and its .result.expected as the expected record, the call waiting for the transfer's own outcome:\n  {runtime} op --fleet --effect-exit --request [REQUEST FILE]\nWhere either refuses or exits nonzero, tell the user a fresh overseer session must be started by hand, then record the handoff and end this session:\n  {runtime} op --fleet --request-json {word}\nWrite the record as it stands above: the two names in it are what end this refusal for this session and for no other. It repeats at every turn end until the succession lands or that record stands."
        )
    }
}

/// The fleet's own work item, whose state file holds the controller's
/// handoff.
pub(super) const OVERSEER_ITEM: &str = "oversee";

/// The flag a Copilot session's automatic compaction leaves in its mailbox.
const COMPACTION_FLAG: &str = "compaction.json";

/// The polls of a standing pending marker before a reading on its way is
/// judged not to arrive in this turn end, and the pause between them.
const PENDING_POLLS: u32 = 25;
const PENDING_POLL: Duration = Duration::from_millis(200);

/// Whether `mailbox`'s compaction flag names `session` (an empty session
/// matching a flag naming none). `Err` with the flag and the cause where
/// one stands and cannot be read as a flag.
fn compaction_flagged(mailbox: &Path, session: &str) -> Result<bool, (PathBuf, String)> {
    let path = mailbox.join(COMPACTION_FLAG);
    if std::fs::symlink_metadata(&path).is_err() {
        return Ok(false);
    }
    let flag = std::fs::read_to_string(&path)
        .map_err(|e| e.to_string())
        .and_then(|text| serde_json::from_str::<Value>(&text).map_err(|e| e.to_string()));
    match flag {
        Ok(Value::Object(flag)) => Ok(match flag.get("session_id") {
            None | Some(Value::Null | Value::Bool(false)) => session.is_empty(),
            Some(Value::String(named)) => named == session,
            Some(_) => false,
        }),
        Ok(_) => Err((path, "not a compaction flag".to_owned())),
        Err(cause) => Err((path, cause)),
    }
}

/// Whether `marker` still stands after the polls, or once the turn end's
/// deadline leaves no time for another.
fn pending_outlasts_wait(marker: &Path, deadline: &Deadline) -> bool {
    let mut polls = 0;
    while std::fs::metadata(marker).is_ok() {
        if polls >= PENDING_POLLS || deadline.left().is_none() {
            return true;
        }
        deadline.pause(PENDING_POLL);
        polls += 1;
    }
    false
}

/// The wall clock in whole seconds, which a status-line record's stamp is
/// judged against.
#[allow(
    clippy::disallowed_methods,
    reason = "the status-line record's freshness, judged against the wall clock its writer stamped it with"
)]
pub(super) fn epoch_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs())
}

/// Pi's model registry read for `model` by the `node` and `pi` on this
/// turn end's `PATH`, within what is left of its deadline; nothing once
/// that is spent.
#[allow(
    clippy::disallowed_methods,
    reason = "Pi's registry window, read by running node over the pi on PATH only where neither the payload nor the record names a window"
)]
fn registry_window(model: &str, agent_dir: &Path, deadline: &Deadline) -> Option<u64> {
    let bound = deadline.left()?;
    let path = std::env::var_os("PATH").unwrap_or_default();
    context::pi_registry_window(model, agent_dir, &path, bound)
}
