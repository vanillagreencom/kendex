//! The turn-end check a harness hook runs at a turn end, a tool call, a
//! session start, a prompt, a compaction, a context reading or a session
//! event: the harness payload on stdin, the harness's answer on stdout and
//! stderr, the harness's exit status. A turn end that finds nothing to hold
//! passes at exit 0 with nothing written.

mod agents;
pub mod answer;
mod controller;
mod copilot;
pub mod identity;
pub mod mail;
mod marks;
pub mod payload;
mod role;
mod rows;
mod wake;

use std::io::Read;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::SystemTime;

use agent_runtime::clock::SystemClock;
use agents::Deadline;
use answer::{Harness, Said};
use identity::Lane;
use payload::{Caller, Leads, Payload};

/// The event a run judges: the argument the hook beside the turn-end hook
/// names, a turn end where it names none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Arm {
    Stop,
    /// Claude's `PostModelSwitch`, which reaches the turn-end hook.
    ModelSwitch,
    /// A tool call about to run.
    Halt,
    /// A Copilot compaction about to begin.
    Compact,
    /// A Copilot session's context reading, which the context extension
    /// hands over.
    Usage,
    /// Whether the session runs in a launched lane, asked at a permission
    /// prompt: it judges and records nothing.
    Lane,
    /// The session's own event row, under the event its row hook names
    /// where the payload spells none.
    Row {
        event: String,
    },
    /// A finished tool call.
    Deliver,
    Start,
    Prompt,
}

impl Arm {
    /// The arm `word` names, a turn end where it is absent or empty; the
    /// word itself where it names none.
    fn parse(word: Option<&str>, event: Option<&str>) -> Result<Arm, String> {
        Ok(match word.unwrap_or_default() {
            "" | "stop" => Arm::Stop,
            "halt" => Arm::Halt,
            "compact" => Arm::Compact,
            "usage" => Arm::Usage,
            "lane" => Arm::Lane,
            "row" => Arm::Row {
                event: event.unwrap_or_default().to_owned(),
            },
            "deliver" => Arm::Deliver,
            "start" => Arm::Start,
            "prompt" => Arm::Prompt,
            other => return Err(other.to_owned()),
        })
    }

    /// The event name the context an arm hands over is written under, for
    /// the arms that hand mail over as context.
    pub fn context_event(&self) -> Option<&'static str> {
        match self {
            Arm::Deliver => Some("PostToolUse"),
            Arm::Start => Some("SessionStart"),
            Arm::Prompt => Some("UserPromptSubmit"),
            Arm::ModelSwitch => Some("PostModelSwitch"),
            Arm::Stop | Arm::Halt | Arm::Compact | Arm::Usage | Arm::Lane | Arm::Row { .. } => None,
        }
    }
}

/// What the harness is handed: stdout, stderr and the exit status.
#[derive(Debug, PartialEq, Eq)]
pub struct Answer {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
    /// The mailbox cursor moved past the lines the answer carried.
    ack: Option<Box<mail::Ack>>,
    /// For a context answer, the exit status the arm's refusal takes.
    unwritten: Option<i32>,
}

impl Answer {
    /// Hand the answer over, stderr then stdout, and return its exit
    /// status. The cursor moves only once stdout is written, so a run that
    /// dies first leaves the lines unread rather than consumed unseen; a
    /// context answer stdout cannot take is refused under
    /// `notice=unwritten` instead, its lines left unread.
    pub fn write(self) -> i32 {
        use std::io::Write;
        let mut stderr = std::io::stderr().lock();
        let _ = stderr.write_all(self.stderr.as_bytes());
        let mut stdout = std::io::stdout().lock();
        let written = stdout
            .write_all(self.stdout.as_bytes())
            .and_then(|()| stdout.flush());
        match (written, self.unwritten) {
            (Ok(()), _) => {
                if let Some(ack) = &self.ack {
                    let _ = stderr.write_all(ack.settle().as_bytes());
                }
                self.code
            }
            (Err(e), Some(code)) => {
                let text = Said::NoticeUnwritten.text(&e.to_string());
                let _ = stderr.write_all(format!("{text}\n").as_bytes());
                code
            }
            (Err(_), None) => self.code,
        }
    }
}

/// A step's way on, or the answer that ends the run.
type Flow<T = ()> = Result<T, Answer>;

/// The environment a turn end reads, each variable once.
struct Vars {
    home: String,
    /// The directory the harness started the session in.
    project_dir: Option<PathBuf>,
    pwd: PathBuf,
    /// The item a lane's launch brief set (`LANE_MAIL_ITEM`).
    item: Option<String>,
    /// A managed Jarvis session names its record (`JARVIS_RECORD`) and the
    /// generation that launched it (`JARVIS_GENERATION`).
    jarvis_record: Option<PathBuf>,
    jarvis_generation: Option<String>,
    /// In tmux with no pane named, where a controller's identity is read
    /// with no lane discovery.
    tmux_without_pane: bool,
    /// The socket `$TMUX` names, its first field.
    tmux_socket: Option<PathBuf>,
    tmux_pane: Option<String>,
    pi_dir: Option<PathBuf>,
    /// The command line's word on the private env file the settings read.
    private_env: bool,
}

impl Vars {
    fn read(private_env: bool) -> Vars {
        let set = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
        Vars {
            home: std::env::var("HOME").unwrap_or_default(),
            project_dir: set("CLAUDE_PROJECT_DIR").map(PathBuf::from),
            pwd: set("PWD")
                .map(PathBuf::from)
                .or_else(|| std::env::current_dir().ok())
                .unwrap_or_default(),
            item: set("LANE_MAIL_ITEM").map(|item| item.to_string_lossy().into_owned()),
            jarvis_record: set("JARVIS_RECORD").map(PathBuf::from),
            jarvis_generation: set("JARVIS_GENERATION")
                .map(|generation| generation.to_string_lossy().into_owned()),
            tmux_without_pane: set("TMUX").is_some() && set("TMUX_PANE").is_none(),
            tmux_socket: set("TMUX").map(|tmux| {
                let tmux = tmux.to_string_lossy().into_owned();
                PathBuf::from(tmux.split(',').next().unwrap_or_default())
            }),
            tmux_pane: set("TMUX_PANE").map(|pane| pane.to_string_lossy().into_owned()),
            pi_dir: set("PI_CODING_AGENT_DIR").map(PathBuf::from),
            private_env,
        }
    }
}

/// One run's answer as it is built: the harness and arm that shape it, the
/// caller the payload names, whether a gap is reported rather than held,
/// and the notes already written for stderr.
struct Turn {
    harness: Harness,
    /// `None` until the argument is read; a refusal of the argument itself
    /// has no arm.
    arm: Option<Arm>,
    caller: Caller,
    /// A continued turn, a tool call, a row and the lane arm report what the
    /// lane cannot clear and pass: holding a continued turn is the loop
    /// `stop_hook_active` exists to end, and a halt the lane could clear only
    /// with the tool call it refuses.
    reported: bool,
    stderr: String,
    /// The cursor move a refusal carrying mail makes once written.
    ack: Option<Box<mail::Ack>>,
    /// The install the hook runs from, as the harness named it.
    hook_dir: PathBuf,
    /// The run's deadline, counted from its start: the agent scan and any
    /// wait keep within it.
    deadline: Deadline<'static>,
    /// Who a session with no lane item is, read once: its pane key from
    /// the start of the judgement, its role once the row arm is past.
    #[allow(
        dead_code,
        reason = "read by the controllers' turn ends, the rows' writer and Copilot usage"
    )]
    role: Rc<role::Role>,
    /// What the controller's tool call or Copilot start hands the model
    /// ahead of the call's own answer.
    notice: Option<Box<controller::Notice>>,
    /// The wake check's notice, said on stderr where it was found and
    /// carried into a later refusal's text.
    wake: Option<String>,
}

impl Turn {
    /// A turn of `harness` from the install at `hook_dir`, before its arm,
    /// caller and role are read: the one constructor every turn takes.
    fn new(harness: Harness, hook_dir: PathBuf) -> Turn {
        Turn {
            harness,
            arm: None,
            caller: Caller::Lead,
            reported: false,
            stderr: String::new(),
            ack: None,
            hook_dir,
            deadline: Deadline::start(&SystemClock),
            role: Rc::new(role::Role::default()),
            notice: None,
            wake: None,
        }
    }

    fn note(&mut self, said: &Said, cause: &str) {
        self.stderr.push_str(&said.text(cause));
        self.stderr.push('\n');
    }

    /// The one exit for a refusal: the text on stderr, and the harness's
    /// shape of it on stdout with its exit status. A finished tool call's
    /// refusal carries the controller's notice ahead of its own text and
    /// records it told, so a refusal never withholds a mark the same call
    /// judged.
    fn refuse(&mut self, said: Said, cause: &str) -> Answer {
        let mut text = said.text(cause);
        if self.arm == Some(Arm::Deliver)
            && let Some(notice) = self.notice.take()
        {
            text = format!("{}\n{text}", notice.text);
            notice.told();
        }
        // The wake's notice already stands on stderr; a harness that reads
        // the refusal from stdout is handed it there too.
        let shaped = match &self.wake {
            Some(wake) => format!("{text}\n{wake}"),
            None => text.clone(),
        };
        let (stdout, code) = answer::refusal(self.harness, self.arm.as_ref(), &shaped);
        let mut stderr = std::mem::take(&mut self.stderr);
        stderr.push_str(&text);
        stderr.push('\n');
        Answer {
            stdout,
            stderr,
            code,
            ack: self.ack.take(),
            unwritten: None,
        }
    }

    /// A gap reported and passed where the turn is [`Turn::reported`],
    /// else refused.
    fn stall(&mut self, said: Said, cause: &str) -> Answer {
        if self.reported {
            self.note(&said, cause);
            return self.pass();
        }
        self.refuse(said, cause)
    }

    fn pass(&mut self) -> Answer {
        self.said("")
    }

    /// A pass with `stdout` written: the lane arm's answer.
    fn said(&mut self, stdout: &str) -> Answer {
        Answer {
            stdout: stdout.to_owned(),
            stderr: std::mem::take(&mut self.stderr),
            code: 0,
            ack: None,
            unwritten: None,
        }
    }

    /// The answer for a session that is no lane: the lane arm says so, any
    /// other arm passes.
    fn no_lane(&mut self) -> Answer {
        if self.arm == Some(Arm::Lane) {
            return self.said("none\n");
        }
        self.pass()
    }
}

/// Judge one hook call: the install at `hook_dir` names the harness, `arm`
/// and `event` the event, `stdin` carries the payload, and `private_env`
/// says whether the settings read the private env file.
pub fn run(
    hook_dir: &Path,
    arm: Option<&str>,
    event: Option<&str>,
    private_env: bool,
    stdin: &mut dyn Read,
) -> Answer {
    let vars = Vars::read(private_env);
    let harness = Harness::of(hook_dir, vars.pi_dir.as_deref());
    let mut turn = Turn::new(harness, hook_dir.to_path_buf());
    match judge(&mut turn, &vars, arm, event, stdin) {
        Ok(()) => turn.pass(),
        Err(answer) => answer,
    }
}

fn judge(
    turn: &mut Turn,
    vars: &Vars,
    arm: Option<&str>,
    event: Option<&str>,
    stdin: &mut dyn Read,
) -> Flow {
    let mut arm = Arm::parse(arm, event).map_err(|word| turn.refuse(Said::Arm(word), ""))?;
    turn.arm = Some(arm.clone());
    let mut bytes = Vec::new();
    if let Err(e) = stdin.read_to_end(&mut bytes) {
        return Err(turn.refuse(Said::PayloadUnreadable, &e.to_string()));
    }
    let payload = Payload::decode(&bytes, arm == Arm::Usage)
        .map_err(|invalid| turn.refuse(Said::PayloadInvalid, &invalid.0))?;
    if payload.model_switch && arm == Arm::Stop {
        arm = Arm::ModelSwitch;
        turn.arm = Some(arm.clone());
    }
    // A Copilot call reaches another harness's install only through a
    // registration kendex no longer writes. That install passes it silently:
    // its answers take a shape Copilot does not read and its caller rules
    // are not Copilot's, so the Copilot install is the one reader of the
    // mailbox for a Copilot call.
    if payload.copilot_call && turn.harness != Harness::Copilot {
        return Err(turn.pass());
    }
    turn.caller = caller(turn, &arm, vars, &payload);
    let continued = arm == Arm::Stop && payload.active;
    turn.reported = continued || matches!(arm, Arm::Halt | Arm::Row { .. } | Arm::Lane);
    // Lane mail belongs to the lane lead: a subagent's finished call,
    // session start or prompt is handed none and acknowledges none, so the
    // lead's own run still finds it unread.
    if arm.context_event().is_some() && turn.caller == Caller::Subagent {
        return Err(turn.pass());
    }
    // A compaction the caller rule does not name the lead's flags nothing
    // for the lead and passes before any gap of the lead's is reached; the
    // unknown caller's automatic one is reported, since a warning at every
    // subagent's compaction would bury the gaps the compact arm refuses.
    if arm == Arm::Compact && turn.caller != Caller::Lead {
        if turn.caller == Caller::Unknown && payload.trigger == "auto" {
            let session = if payload.session.is_empty() {
                "none"
            } else {
                &payload.session
            };
            turn.note(&Said::CompactionUnrecorded(session.to_owned()), "");
        }
        return Err(turn.pass());
    }
    let lane = Lane::read(turn, vars, &payload)?;
    if arm == Arm::Lane {
        let answer = if lane.launched(turn)? {
            "lane\n"
        } else {
            "none\n"
        };
        return Err(turn.said(answer));
    }
    judged(turn, vars, &arm, &lane, &payload, continued)
}

/// Who made the call: the payload names a subagent on every harness, and
/// Copilot's lead is settled by event, as Copilot CLI was measured sending
/// a lead and a custom subagent it started. A session start is the lead's
/// own and records it; a turn end whose transcript sits in a directory
/// named for its session is the lead's and records it, one naming another
/// session's directory a subagent's; a tool call, a compaction and a
/// context reading are the lead's only where the session is a recorded
/// lead. A prompt is the lead's and records nothing.
fn caller(turn: &mut Turn, arm: &Arm, vars: &Vars, payload: &Payload) -> Caller {
    if payload.caller != Caller::Lead || turn.harness != Harness::Copilot {
        return payload.caller;
    }
    let leads = Leads::under(&vars.home);
    let session = &payload.session;
    let record = |turn: &mut Turn, prune: bool| {
        for note in leads.record(session, prune, wall_now()) {
            turn.note(&note.said, &note.cause);
        }
    };
    match arm {
        Arm::Start => record(turn, true),
        Arm::Stop if !payload.transcript.is_empty() && !session.is_empty() => {
            let dir = payload
                .transcript
                .rsplit_once('/')
                .map_or(payload.transcript.as_str(), |(dir, _)| dir);
            let dir = dir.rsplit_once('/').map_or(dir, |(_, name)| name);
            if dir != session {
                return Caller::Subagent;
            }
            record(turn, false);
        }
        Arm::Deliver | Arm::Halt | Arm::Compact | Arm::Usage => {
            if !leads.recorded(session) {
                return Caller::Unknown;
            }
        }
        Arm::Stop | Arm::ModelSwitch | Arm::Lane | Arm::Row { .. } | Arm::Prompt => {}
    }
    Caller::Lead
}

/// The wall clock a lead record is stamped with and pruned against.
#[allow(
    clippy::disallowed_methods,
    reason = "the turn end's one wall-clock read: the Copilot lead record's stamp and its prune, in the user's cache"
)]
fn wall_now() -> SystemTime {
    SystemTime::now()
}

/// The decisions past the lane's identity, in the order a turn end takes
/// them. Each is a place of its own; a place that holds nothing lets the
/// next judge, and a turn end none holds passes.
fn judged(
    turn: &mut Turn,
    vars: &Vars,
    arm: &Arm,
    lane: &Lane,
    payload: &Payload,
    continued: bool,
) -> Flow {
    role::session_pane(turn, vars, lane, payload)?;
    if let Arm::Row { .. } = arm {
        if lane.item.is_none() {
            rows::session_row(turn, vars, lane, payload)?;
        }
        return Ok(());
    }
    role::read(turn, vars, lane, payload);
    match arm {
        Arm::Compact => return copilot::compaction_mark(turn, vars, lane, payload),
        Arm::Usage => return copilot::usage_read(turn, vars, lane, payload),
        Arm::Stop
        | Arm::ModelSwitch
        | Arm::Halt
        | Arm::Lane
        | Arm::Row { .. }
        | Arm::Deliver
        | Arm::Start
        | Arm::Prompt => {}
    }
    rows::lane_row(turn, vars, lane, payload)?;
    rows::jarvis_row(turn, vars, lane, payload)?;
    let lead = turn.caller == Caller::Lead;
    if *arm == Arm::Start && turn.harness == Harness::Copilot && lead {
        controller::context_reader_check(turn, vars, lane, payload)?;
    }
    if *arm == Arm::Deliver && lane.item.is_none() && lead {
        controller::overseer_tool_check(turn, vars, lane, payload)?;
    }
    if *arm == Arm::ModelSwitch {
        return model_switch();
    }
    if !continued {
        mail::check(turn, vars, arm, lane, payload)?;
    }
    if *arm == Arm::Halt {
        if lane.item.is_some() {
            mail::question_tool_check(turn, vars, lane, payload)?;
        }
        marks::attached_launch_check(turn, lane, vars, payload)?;
    }
    marks::handoff_check(turn, arm, lane, vars, payload)?;
    mail::idle_check(turn, vars, arm, lane, continued)
}

/// Where a model switch is recorded or handed off; it records nothing.
fn model_switch() -> Flow {
    Ok(())
}
