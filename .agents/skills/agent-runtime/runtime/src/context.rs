//! What a harness session's context holds, read from the file the harness
//! itself writes for the session and never from a pane: the tokens the last
//! response left in the context, the window a reading is judged against
//! where that window is a verified point, and the model. One reader per
//! harness, for every caller; a value only the caller's own rules know (a
//! launch's compaction overrides, a window a hook payload named) comes in
//! as an argument.

use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Map, Value};

use crate::harness::Harness;
use crate::reading::Reading;

/// What one read of a session's file found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Usage {
    /// The last usage line's figures. `window` is the point the harness
    /// stops or compacts at where that point is verified, `None` where the
    /// effective configuration leaves it unresolved.
    Measured {
        tokens: u64,
        window: Option<u64>,
        model: String,
    },
    /// The last usage line carries none of the harness's field names: a
    /// figure stands in the file and this reader cannot take it, which is
    /// never read as zero.
    Unread,
    /// No line carries usage yet.
    Absent,
}

/// The bytes read from a transcript's end before the whole file is: a
/// session's last usage line sits near its end, and a long session's file
/// is many times this.
pub const TAIL_BYTES: u64 = 1_048_576;

/// The usage `read` takes from the session file at `path`, the whole file's
/// reading: its last usage line and the model the file last names. The last
/// [`TAIL_BYTES`] are a shortcut that stands where they hold a usage line
/// and, for a measured one, a model; otherwise the whole file is read, since
/// a harness may name the model once near the head (a Codex rollout's one
/// `turn_context`, megabytes before its last token count). The tail opens on
/// a partial line, which `read` passes over as it passes over any line that
/// is no JSON (the line the harness is still appending included). `Err`
/// where the file cannot be opened or read, or where `read` refuses a line
/// it cannot sum.
pub fn read_file(
    path: &Path,
    read: impl Fn(&str) -> Result<Usage, String>,
) -> Result<Usage, String> {
    tail_first(path, read, |tail| match tail {
        Usage::Measured { model, .. } => !model.is_empty(),
        Usage::Unread => true,
        Usage::Absent => false,
    })
}

/// What `read` takes from the file at `path`: from its last [`TAIL_BYTES`]
/// where that reading `stands`, else from the whole file.
fn tail_first<T>(
    path: &Path,
    read: impl Fn(&str) -> Result<T, String>,
    stands: impl Fn(&T) -> bool,
) -> Result<T, String> {
    let fail = |e: io::Error| format!("{}: {e}", path.display());
    let mut file = File::open(path).map_err(fail)?;
    let len = file.metadata().map_err(fail)?.len();
    if len > TAIL_BYTES {
        file.seek(SeekFrom::Start(len - TAIL_BYTES)).map_err(fail)?;
        let tail = read(&lossy(&mut file).map_err(fail)?)?;
        if stands(&tail) {
            return Ok(tail);
        }
        file.seek(SeekFrom::Start(0)).map_err(fail)?;
    }
    read(&lossy(&mut file).map_err(fail)?)
}

fn lossy(file: &mut File) -> io::Result<String> {
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Each line of `text` that is a JSON object; any other line is skipped.
fn objects(text: &str) -> impl Iterator<Item = Map<String, Value>> + '_ {
    text.lines()
        .filter_map(|line| match serde_json::from_str(line) {
            Ok(Value::Object(object)) => Some(object),
            _ => None,
        })
}

/// The sum of the named usage fields, an absent or null field counting 0;
/// `Err` where one holds anything but a whole count.
fn summed(usage: &Map<String, Value>, fields: &[&str]) -> Result<u64, String> {
    fields.iter().try_fold(0u64, |sum, field| {
        let count = match usage.get(*field) {
            None | Some(Value::Null) => 0,
            Some(value) => value
                .as_u64()
                .ok_or_else(|| format!("usage field {field} is no whole count: {value}"))?,
        };
        Ok(sum.saturating_add(count))
    })
}

fn word<'a>(object: &'a Map<String, Value>, key: &str) -> &'a str {
    object.get(key).and_then(Value::as_str).unwrap_or_default()
}

/// What one line of a session's file records of one model response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Response {
    Spent(Spent),
    /// The line carries usage under none of the harness's field names: a
    /// figure stands and this reader cannot take it, never read as zero.
    Unread,
    /// The line records a response whose usage its writer never counted:
    /// no figure, and the output it added reaches the next response's
    /// prompt with no count of its own. The model is the one the line
    /// names, which its missing counts do not make unknown.
    Uncounted {
        model: String,
    },
}

/// One response's figures.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Spent {
    /// What names the response on every line that records it: a Claude
    /// Code message spans one line per content block, each carrying the
    /// message's usage, and a Codex `token_count` event can repeat the
    /// response before it, with the session's running total unchanged.
    pub id: Option<String>,
    /// The tokens the response left in the context.
    pub context: u64,
    /// The prompt and the output the context is made of, where the line
    /// names them apart.
    pub split: Option<Split>,
    /// The window the line names, as the harness wrote it.
    pub window: Option<u64>,
    pub model: String,
}

/// A response's prompt-side tokens, everything the request carried, and
/// its output, which the next request carries back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Split {
    pub prompt: u64,
    pub output: u64,
}

/// The response one line of `harness`'s session file records, `None` for a
/// line that records none: the one reading of a line's usage, behind both
/// [`read_file`]'s last reading and a whole walk of the file. A Copilot
/// CLI session's last reading is [`copilot_session`]'s instead, the CLI's
/// own count, which no response line carries. `Err` where a usage field
/// holds anything but a whole count.
pub fn response(harness: Harness, line: &Map<String, Value>) -> Result<Option<Response>, String> {
    match harness {
        Harness::Claude => claude_response(line),
        Harness::Codex => Ok(codex_response(line)),
        Harness::Pi => pi_response(line),
        Harness::Copilot => copilot_response(line),
    }
}

/// A Copilot CLI `session.usage_record` row's `data.usage`, one model
/// call's. The SDK's per-call interface is the `assistant.usage` event, and
/// it cannot serve a read of a saved session: it is ephemeral, never
/// written to `events.jsonl`. The usage record is its durable receipt, its
/// `data.usage` the same `AssistantUsageData` (Copilot CLI 1.0.116
/// `schemas/session-events.schema.json`: `AssistantUsageEvent.ephemeral`
/// is `const true`, `UsageAccountingRecordData.usage` references
/// `AssistantUsageData`). The fields read are `inputTokens`, the whole
/// prompt, the fresh input with `cacheReadTokens` and `cacheWriteTokens`
/// (2 + 290185 + 699 = 290886 in a recorded 1.0.112 log); `outputTokens`,
/// the output; `model`; and `interactionType`. A call whose
/// `interactionType` is present and not one of [`COPILOT_LEAD_CALLS`] (a
/// sub-agent, sampling, background or compaction call; the schema writes no
/// `agentId` on a session-level row, so the lead's rows include it) sent a
/// prompt of its own, not the lead conversation's, and records no response
/// of it. A producer that classes no call is read as the lead's.
fn copilot_response(line: &Map<String, Value>) -> Result<Option<Response>, String> {
    if word(line, "type") != "session.usage_record" {
        return Ok(None);
    }
    let Some(Value::Object(usage)) = line.get("data").and_then(|data| data.get("usage")) else {
        return Ok(Some(Response::Unread));
    };
    if let Some(class) = usage.get("interactionType").and_then(Value::as_str)
        && !COPILOT_LEAD_CALLS.contains(&class)
    {
        return Ok(None);
    }
    if !COPILOT_FIELDS.iter().any(|f| usage.contains_key(*f)) {
        return Ok(Some(Response::Unread));
    }
    let split = Split {
        prompt: summed(usage, &COPILOT_FIELDS[..1])?,
        output: summed(usage, &COPILOT_FIELDS[1..])?,
    };
    Ok(Some(Response::Spent(Spent {
        id: None,
        context: split.prompt.saturating_add(split.output),
        split: Some(split),
        window: None,
        model: word(usage, "model").to_owned(),
    })))
}

/// A Copilot CLI usage record's prompt and output counts.
const COPILOT_FIELDS: [&str; 2] = ["inputTokens", "outputTokens"];

/// The `interactionType` values of a call the lead conversation makes,
/// from the 1.0.116 schema's list: the agent's own follow-up and the call
/// carrying a user prompt.
const COPILOT_LEAD_CALLS: [&str; 2] = ["conversation-agent", "conversation-user"];

/// A Claude Code assistant line's usage: the prompt is the input with both
/// cache counts, the output its `output_tokens`. A line naming the
/// [`CLAUDE_SYNTHETIC`] model records no response.
fn claude_response(line: &Map<String, Value>) -> Result<Option<Response>, String> {
    let Some(Value::Object(message)) = line.get("message") else {
        return Ok(None);
    };
    let Some(Value::Object(usage)) = message.get("usage") else {
        return Ok(None);
    };
    if message.get("model").and_then(Value::as_str) == Some(CLAUDE_SYNTHETIC) {
        return Ok(None);
    }
    if !CLAUDE_FIELDS.iter().any(|f| usage.contains_key(*f)) {
        return Ok(Some(Response::Unread));
    }
    let split = Split {
        prompt: summed(usage, &CLAUDE_FIELDS[..3])?,
        output: summed(usage, &CLAUDE_FIELDS[3..])?,
    };
    Ok(Some(Response::Spent(Spent {
        id: Some(word(message, "id"))
            .filter(|id| !id.is_empty())
            .map(str::to_owned),
        context: split.prompt.saturating_add(split.output),
        split: Some(split),
        window: None,
        model: word(message, "model").to_owned(),
    })))
}

/// A Codex `token_count` event's `last_token_usage`: its `total_tokens` is
/// the context, `input_tokens` (cached input included) the prompt and
/// `output_tokens` the output (`TokenUsage` in Codex's
/// `codex-rs/protocol/src/protocol.rs`, rust-v0.171.0). An event with no
/// `info` object records no response; one whose usage holds no total is
/// unread. The model is the `turn_context`'s, which this line does not name.
///
/// The id is `info.total_token_usage.total_tokens`, the session's running
/// total: an event whose total did not change repeats the response before
/// it, the rule pi-codex-bridge's README § Usage records holds over the
/// rollouts real Codex releases write in its fixture suite.
fn codex_response(line: &Map<String, Value>) -> Option<Response> {
    if word(line, "type") != "event_msg" {
        return None;
    }
    let payload = line.get("payload")?;
    if payload.get("type").and_then(Value::as_str) != Some("token_count") {
        return None;
    }
    let Some(Value::Object(info)) = payload.get("info") else {
        return None;
    };
    let usage = info.get("last_token_usage");
    let count = |key: &str| usage.and_then(|u| u.get(key)).and_then(Value::as_u64);
    let Some(context) = count("total_tokens") else {
        return Some(Response::Unread);
    };
    let split = count("input_tokens")
        .zip(count("output_tokens"))
        .map(|(prompt, output)| Split { prompt, output });
    let running = info
        .get("total_token_usage")
        .and_then(|u| u.get("total_tokens"))
        .and_then(Value::as_u64);
    Some(Response::Spent(Spent {
        id: running.map(|total| total.to_string()),
        context,
        split,
        window: info.get("model_context_window").and_then(Value::as_u64),
        model: String::new(),
    }))
}

/// A Pi message's usage: the input with both cache counts is the prompt,
/// `output` the output, the sum Pi's own `totalTokens` is; the response's
/// id is the entry's own `id`. A [`PI_CODEX`] message whose every count is
/// zero is [`Response::Uncounted`]. The model is spelled `provider/id`
/// where the message names its provider.
fn pi_response(line: &Map<String, Value>) -> Result<Option<Response>, String> {
    let Some(Value::Object(message)) = line.get("message") else {
        return Ok(None);
    };
    let Some(Value::Object(usage)) = message.get("usage") else {
        return Ok(None);
    };
    if !PI_FIELDS.iter().any(|f| usage.contains_key(*f)) {
        return Ok(Some(Response::Unread));
    }
    let split = Split {
        prompt: summed(usage, &["input", "cacheRead", "cacheWrite"])?,
        output: summed(usage, &["output"])?,
    };
    let (provider, id) = (word(message, "provider"), word(message, "model"));
    let model = if provider.is_empty() || id.is_empty() {
        id.to_owned()
    } else {
        format!("{provider}/{id}")
    };
    if provider == PI_CODEX && split.prompt == 0 && split.output == 0 {
        return Ok(Some(Response::Uncounted { model }));
    }
    Ok(Some(Response::Spent(Spent {
        id: Some(word(line, "id"))
            .filter(|id| !id.is_empty())
            .map(str::to_owned),
        context: split.prompt.saturating_add(split.output),
        split: Some(split),
        window: None,
        model,
    })))
}

/// The prompt-side and response-side counts of a Claude Code usage object:
/// the input with both cache counts is the prompt the line was billed for,
/// and the output is sent back with the next request.
const CLAUDE_FIELDS: [&str; 4] = [
    "input_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
    "output_tokens",
];

/// The model a Claude Code transcript names on an API error it records,
/// every count zero: no reading of the session.
const CLAUDE_SYNTHETIC: &str = "<synthetic>";

/// One reading of a Claude Code transcript: the last assistant message
/// carrying a usage object, against the model's capacity or its default
/// auto-compact threshold.
pub fn claude(text: &str, compaction_off: bool) -> Result<Usage, String> {
    let mut last = Usage::Absent;
    for line in objects(text) {
        match claude_response(&line)? {
            None | Some(Response::Uncounted { .. }) => {}
            Some(Response::Unread) => last = Usage::Unread,
            Some(Response::Spent(spent)) => {
                last = Usage::Measured {
                    tokens: spent.context,
                    window: Harness::Claude
                        .context_capacity(&spent.model)
                        .map(|capacity| {
                            // Claude Code defaults to 967K on native 1M models: https://code.claude.com/docs/en/model-config#default-auto-compact-thresholds
                            if !compaction_off && capacity == 1_000_000 {
                                967_000
                            } else {
                                capacity
                            }
                        }),
                    model: spent.model,
                };
            }
        }
    }
    Ok(last)
}

/// Whether the environment a Claude Code session was launched with turns its
/// automatic compaction off: the value its launch words set, which the
/// session's hooks inherit.
pub fn claude_compaction_off() -> bool {
    ["DISABLE_AUTO_COMPACT", "DISABLE_COMPACT"]
        .iter()
        .any(|name| std::env::var(name).is_ok_and(|value| value == "1"))
}

/// One reading of a Codex rollout: the last `token_count` event's
/// `last_token_usage.total_tokens`, the model the last `turn_context` names.
/// The event's `model_context_window` is the verified point only where
/// `floor`, the count below which the session's settings let no compaction
/// fire ([`codex_compaction_floor`]), is no smaller than that window; no
/// floor leaves the point unresolved and never discards the count.
pub fn codex(text: &str, floor: Option<u64>) -> Result<Usage, String> {
    let mut turn = Named::default();
    let mut last: Option<Option<(u64, Option<u64>)>> = None;
    for line in objects(text) {
        if word(&line, "type") == "turn_context" {
            turn.take_turn(line.get("payload"));
            continue;
        }
        match codex_response(&line) {
            None | Some(Response::Uncounted { .. }) => {}
            Some(Response::Unread) => last = Some(None),
            Some(Response::Spent(spent)) => {
                last = Some(Some((
                    spent.context,
                    spent.window.filter(|w| floor.is_some_and(|f| f >= *w)),
                )));
            }
        }
    }
    Ok(match last {
        None => Usage::Absent,
        Some(None) => Usage::Unread,
        Some(Some((tokens, window))) => Usage::Measured {
            tokens,
            window,
            model: turn.model,
        },
    })
}

/// What a session's own record names it runs on: the model and the
/// reasoning effort, each empty where the record names none.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Named {
    pub model: String,
    pub effort: String,
}

impl Named {
    /// Each member a Codex `turn_context` payload names, which the last
    /// such line that names it holds: the payload carries both under these
    /// keys (measured on Codex 0.167.2).
    fn take_turn(&mut self, payload: Option<&Value>) {
        for (key, member) in [("model", &mut self.model), ("effort", &mut self.effort)] {
            if let Some(Value::String(named)) = payload.and_then(|p| p.get(key)) {
                named.clone_into(member);
            }
        }
    }
}

/// What the `turn_context` lines of the rollout at `path` name, under
/// [`read_file`]'s rule: the tail stands where it names a model, else the
/// whole file is read. `Err` where the file cannot be opened or read.
pub fn codex_turn(path: &Path) -> Result<Named, String> {
    tail_first(
        path,
        |text| {
            let mut turn = Named::default();
            for line in objects(text) {
                if word(&line, "type") == "turn_context" {
                    turn.take_turn(line.get("payload"));
                }
            }
            Ok(turn)
        },
        |turn| !turn.model.is_empty(),
    )
}

/// Where a session's own record is found: the file the caller names, else
/// the one the session's id names under the harness home for `cwd`; for
/// Copilot CLI the status-line record under that home, judged at `now`
/// (seconds since the epoch) and bound to the transcript where one is named.
struct SessionAt<'a> {
    harness: Harness,
    session: &'a str,
    transcript: Option<&'a Path>,
    home: Option<&'a Path>,
    cwd: &'a Path,
    now: u64,
}

/// A session's own record that could not be read: a stable key and the
/// cause where one was given. It is an unknown, never a record that names
/// nothing, so the launch's declaration never stands in for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordUnread {
    pub key: &'static str,
    pub cause: String,
}

/// One member of what a session runs on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Member {
    /// The session's own record names it.
    Session(String),
    /// The session's own record names none and the launch declared it.
    Launch(String),
    /// Neither names it.
    Unrecorded,
}

impl Member {
    fn of(named: &str, declared: Option<&str>) -> Member {
        if !named.is_empty() {
            return Member::Session(named.to_owned());
        }
        match declared.filter(|word| !word.is_empty()) {
            Some(word) => Member::Launch(word.to_owned()),
            None => Member::Unrecorded,
        }
    }
}

/// The model and the effort a session runs on now, each its own answer, and
/// the name its launch gave it, which no session record holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Now {
    pub model: Result<Member, RecordUnread>,
    pub effort: Result<Member, RecordUnread>,
    pub agent: Member,
}

/// Whether `harness`'s own session record is measured to carry the effort:
/// a Codex `turn_context` does. Claude Code's transcript, Copilot CLI's
/// status-line record and Pi's session file are not, so their effort is
/// unrecorded: the effort a launch asked for is no reading of the one the
/// session runs on.
fn effort_recorded(harness: Harness) -> bool {
    match harness {
        Harness::Codex => true,
        Harness::Claude | Harness::Copilot | Harness::Pi => false,
    }
}

/// What `session model` answers for the session `at` names: the model from
/// the session's own record first, and from the launch's `declared_model`
/// only where that record names none; the effort from that record alone;
/// the name from the launch's `declared_agent` alone. A member the record
/// cannot be read for is that failure.
fn session_now(at: &SessionAt, declared_model: Option<&str>, declared_agent: Option<&str>) -> Now {
    let named = session_named(at);
    let effort = match &named {
        Err(unread) if effort_recorded(at.harness) => Err(unread.clone()),
        Ok(named) if effort_recorded(at.harness) => Ok(Member::of(&named.effort, None)),
        Ok(_) | Err(_) => Ok(Member::Unrecorded),
    };
    Now {
        model: named.map(|named| Member::of(&named.model, declared_model)),
        effort,
        agent: Member::of("", declared_agent),
    }
}

/// [`session_now`] for the calling session `session` of `harness`, read
/// where this process runs: the harness home its variable names, else the
/// harness's default; the working directory; the clock; and the launch's
/// declarations in this process's environment, which only a process the
/// session itself runs inherits. The one reading behind `agent-runtime
/// session model` and orch's call for the session bound at its pane.
pub fn calling_session(harness: Harness, session: &str, transcript: Option<&Path>) -> Now {
    let home = std::env::var_os(harness.home_var())
        .filter(|home| !home.is_empty())
        .map(PathBuf::from)
        .or_else(|| crate::session::default_home(harness));
    let cwd = std::env::current_dir().unwrap_or_default();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let declared = |name: &str| std::env::var(name).ok();
    session_now(
        &SessionAt {
            harness,
            session,
            transcript,
            home: home.as_deref(),
            cwd: &cwd,
            now,
        },
        declared(crate::launch::LAUNCH_MODEL_VAR).as_deref(),
        declared(crate::launch::LAUNCH_AGENT_VAR).as_deref(),
    )
}

impl Now {
    /// The three lines `session model` prints, model, effort, agent:
    /// `<member>=<value> source=session|launch`, `session-<member>-unrecorded
    /// harness= session=` where neither names it, or the read's own key with
    /// the harness, the session and its cause.
    pub fn lines(&self, harness: Harness, session: &str) -> [String; 3] {
        let line = |member: &str, answer: &Result<Member, RecordUnread>| match answer {
            Ok(Member::Session(word)) => format!("{member}={word} source=session"),
            Ok(Member::Launch(word)) => format!("{member}={word} source=launch"),
            Ok(Member::Unrecorded) => {
                format!("session-{member}-unrecorded harness={harness} session={session}")
            }
            Err(unread) if unread.cause.is_empty() => {
                format!("{} harness={harness} session={session}", unread.key)
            }
            Err(unread) => format!(
                "{} harness={harness} session={session} cause={}",
                unread.key, unread.cause
            ),
        };
        [
            line("model", &self.model),
            line("effort", &self.effort),
            line("agent", &Ok(self.agent.clone())),
        ]
    }

    /// 0 where every member answers, 1 where one is unrecorded by name, 2
    /// where a read failed: a refusal and an unknown are different answers.
    pub fn exit_code(&self) -> i32 {
        let agent = Ok(self.agent.clone());
        let answers = [&self.model, &self.effort, &agent];
        if answers.iter().any(|answer| answer.is_err()) {
            2
        } else if answers
            .iter()
            .any(|answer| matches!(answer, Ok(Member::Unrecorded)))
        {
            1
        } else {
            0
        }
    }
}

/// What the session's own record names: its model on every harness, its
/// effort where [`effort_recorded`].
fn session_named(at: &SessionAt) -> Result<Named, RecordUnread> {
    let unread = |key: &'static str, cause: String| RecordUnread { key, cause };
    let home = || {
        at.home
            .ok_or_else(|| unread("harness-home-unnamed", String::new()))
    };
    let file = || match at.transcript {
        Some(path) => Ok(path.to_path_buf()),
        None => match crate::session::fixed_id_file(at.harness, home()?, at.cwd, at.session) {
            Reading::Live(path) => Ok(path),
            Reading::Gone => Err(unread("session-file-absent", String::new())),
            Reading::Unreadable { cause } => {
                Err(unread("session-file-unreadable", cause.to_owned()))
            }
        },
    };
    let failed = |cause: String| unread("session-file-unreadable", cause);
    let model = |usage: Usage| Named {
        model: match usage {
            Usage::Measured { model, .. } => model,
            Usage::Unread | Usage::Absent => String::new(),
        },
        effort: String::new(),
    };
    match at.harness {
        Harness::Codex => codex_turn(&file()?).map_err(failed),
        Harness::Claude => read_file(&file()?, |text| claude(text, false))
            .map(model)
            .map_err(failed),
        Harness::Pi => tail_first(&file()?, pi_model, |model| !model.is_empty())
            .map(|model| Named {
                model,
                effort: String::new(),
            })
            .map_err(failed),
        Harness::Copilot => {
            let transcript = at
                .transcript
                .map(|path| path.display().to_string())
                .unwrap_or_default();
            copilot_record(home()?, at.session, &transcript, at.now)
                .map(|record| Named {
                    model: record.model,
                    effort: String::new(),
                })
                .map_err(|reason| unread("session-record-unread", reason.to_owned()))
        }
    }
}

/// The token count below which a Codex session never compacts, from the
/// settings it runs with: `overrides`, the compaction settings its launch
/// recorded (`launch::codex_compaction_overrides`, empty for a launch whose
/// command carries none and unset for a session no launch started), over
/// its home's `config`, as Codex layers its session flags over the user
/// config. `Some` only where those settings name a whole-number
/// `model_auto_compact_token_limit` under the `body_after_prefix` scope with
/// a post-turn threshold of 0 and turn background compaction off in a
/// spelling this reader classifies, or leave it unnamed:
/// under the `total` scope Codex caps the limit at 90% of the window, a
/// post-turn threshold compacts at that share of it, and background
/// compaction starts by default at 65% (openai/codex rust-v0.172.0,
/// `core/src/session/context_window.rs`,
/// `protocol/src/openai_models.rs` `auto_compact_token_limit`,
/// `core/src/session/async_compaction.rs` and `core/src/config/mod.rs`
/// `DEFAULT_ASYNC_COMPACTION_THRESHOLD_PERCENT`). Any of the three compaction
/// keys no layer sets counts as unknown, never as Codex's default, so a
/// default a later release changes verifies no point. An absent background
/// switch is read at Codex's default, off (`features/src/lib.rs`, the
/// `async_compaction` `FeatureSpec`, `default_enabled: false`); that reading
/// stops holding once Codex turns `async_compaction` on by default.
/// Overrides that are no launch's JSON leave the floor unresolved; a config
/// that stands and cannot be read is `Err`. Not read: Codex's project,
/// managed and system layers, the `$CODEX_HOME/<name>.config.toml` profile
/// layer, a launched session's command words other than the three
/// compaction keys (feature switches and `-p`/`--profile`), and the command
/// words of a session no launch recorded.
pub fn codex_compaction_floor(
    overrides: Option<&str>,
    config: &Path,
) -> Result<Option<u64>, SettingsUnread> {
    let text = crate::trust::config_text(config, Harness::Codex)
        .map_err(|e| SettingsUnread {
            file: config.to_path_buf(),
            cause: e.to_string(),
        })?
        .unwrap_or_default();
    let flags = match overrides
        .filter(|o| !o.is_empty())
        .map(serde_json::from_str)
    {
        None => Map::new(),
        Some(Ok(Value::Object(o))) if o.get("harness").and_then(Value::as_str) == Some("codex") => {
            match o.get("settings") {
                Some(Value::Object(s)) => s.clone(),
                _ => return Ok(None),
            }
        }
        Some(_) => return Ok(None),
    };
    let setting = |key: &str| match flags.get(key) {
        Some(Value::String(text)) => Some(text.clone()),
        Some(other) => Some(other.to_string()),
        None => crate::trust::toml_value(&text, "", key),
    };
    // Codex's own feature writer spells the switch as `[features]`
    // `async_compaction = true`; its table form carries `enabled`. A legacy
    // profile the config selects carries its own `features`. Any other
    // mention of `async_compaction`, such as a dotted key, an inline table,
    // a quoted header or another profile's switch that `-p` may select, is
    // a spelling this reader cannot judge, so it verifies no point.
    let profile = crate::trust::toml_value(&text, "", "profile");
    let features: Vec<String> = std::iter::once(String::new())
        .chain(profile.map(|p| format!("profiles.{p}.")))
        .map(|prefix| format!("{prefix}features"))
        .collect();
    let mut table = "";
    for line in text.lines() {
        let header = crate::trust::table_of(line, &mut table);
        let body = line.split('#').next().unwrap_or("");
        if !body.contains("async_compaction") {
            continue;
        }
        let switch = if header {
            features
                .iter()
                .any(|f| table.strip_prefix(f.as_str()) == Some(".async_compaction"))
                .then(|| crate::trust::toml_value(&text, table, "enabled"))
                .flatten()
        } else {
            body.split_once('=')
                .filter(|(key, _)| {
                    key.trim() == "async_compaction" && features.iter().any(|f| f == table)
                })
                .map(|(_, value)| value.trim().to_owned())
        };
        if switch.as_deref() != Some("false") {
            return Ok(None);
        }
    }
    if setting("model_auto_compact_token_limit_scope").as_deref() != Some("body_after_prefix")
        || setting("model_post_turn_compact_threshold_percent").as_deref() != Some("0")
    {
        return Ok(None);
    }
    Ok(setting("model_auto_compact_token_limit")
        .filter(|limit| !limit.is_empty() && limit.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|limit| limit.parse::<u64>().ok()))
}

/// Pi's usage fields: input, output and both cache counts, the sum Pi's
/// own `totalTokens` is.
const PI_FIELDS: [&str; 4] = ["input", "output", "cacheRead", "cacheWrite"];

/// The provider pi-codex-bridge names its messages by. A message of it
/// that ends in a tool call keeps the bridge's `emptyUsage()`, every count
/// zero: Codex's rollout holds the turn's usage, and the message none (the
/// bridge's README § Usage records).
const PI_CODEX: &str = "pi-codex";

/// One reading of a Pi session file: the last message carrying a usage
/// object, its model spelled `provider/id` where the message names its
/// provider, the way the account a Pi session spends is named. A message
/// whose usage its writer never counted leaves the reading before it where
/// both name one model, and leaves it unread where they do not: the count
/// before is another model's, judged against another window. Pi keeps no
/// window in that file, so where `compaction_off` the window is the one
/// `window` finds for the reading's model, and `None` otherwise: enabled
/// compaction has no verified point.
pub fn pi(
    text: &str,
    compaction_off: bool,
    window: impl FnOnce(&str) -> Option<u64>,
) -> Result<Usage, String> {
    let mut last = Usage::Absent;
    for line in objects(text) {
        match pi_response(&line)? {
            None => {}
            Some(Response::Uncounted { model: now }) => {
                if let Usage::Measured { model, .. } = &last
                    && *model != now
                {
                    last = Usage::Unread;
                }
            }
            Some(Response::Unread) => last = Usage::Unread,
            Some(Response::Spent(spent)) => {
                last = Usage::Measured {
                    tokens: spent.context,
                    window: None,
                    model: spent.model,
                };
            }
        }
    }
    if let Usage::Measured {
        window: point,
        model,
        ..
    } = &mut last
        && compaction_off
    {
        *point = window(model);
    }
    Ok(last)
}

/// The model a Pi session file's last response names, whether or not its
/// writer counted it, empty where that response's usage is unread or no
/// line records one: the model behind `session model`, which a response's
/// missing counts do not make unknown.
fn pi_model(text: &str) -> Result<String, String> {
    let mut last = String::new();
    for line in objects(text) {
        match pi_response(&line)? {
            None => {}
            Some(Response::Spent(Spent { model, .. }) | Response::Uncounted { model }) => {
                last = model;
            }
            Some(Response::Unread) => last.clear(),
        }
    }
    Ok(last)
}

/// A harness's settings file that is there and cannot be read: the file,
/// and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsUnread {
    pub file: PathBuf,
    pub cause: String,
}

/// Whether Pi would compact a session under the user settings file `user`
/// and the project one `project`: `false` only where the user file turns
/// `compaction.enabled` off and the project file does not turn it back on.
/// An absent key or file is Pi's default, on. The project file counts only
/// toward compaction: Pi applies it only in a workspace it trusts, so a
/// project `false` may be ignored where a project `true` may not.
pub fn pi_compaction_on(user: &Path, project: &Path) -> Result<bool, SettingsUnread> {
    let user_enabled = pi_enabled(user)?;
    if pi_enabled(project)? == Some(Value::Bool(true)) {
        return Ok(true);
    }
    Ok(user_enabled != Some(Value::Bool(false)))
}

/// The `compaction.enabled` value `file` sets, `None` where it sets none or
/// is not there.
fn pi_enabled(file: &Path) -> Result<Option<Value>, SettingsUnread> {
    let unread = |cause: String| SettingsUnread {
        file: file.to_path_buf(),
        cause,
    };
    let text = match std::fs::read_to_string(file) {
        Ok(text) => text,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(unread(e.to_string())),
    };
    let value: Value = serde_json::from_str(&text).map_err(|e| unread(e.to_string()))?;
    Ok(value
        .get("compaction")
        .and_then(Value::as_object)
        .and_then(|c| c.get("enabled"))
        .cloned())
}

/// The script `node` runs to read Pi's own model registry from the install
/// the `pi` it is handed runs.
const PI_REGISTRY_WINDOW: &str = include_str!("pi-registry-window.mjs");

/// The window Pi's own model registry holds for `model`, spelled
/// `provider/id`: read by the `node` on `path` through the SDK of the first
/// `pi` there, offline and against the Pi user directory `agent_dir`,
/// within `bound`. `None` where `model` names no provider, `path` holds no
/// `pi` or no `node`, the read fails or outlasts the bound, or it prints no
/// whole window. The read takes about a second, so a caller runs it only
/// where nothing it already holds names a window.
pub fn pi_registry_window(
    model: &str,
    agent_dir: &Path,
    path: &OsStr,
    bound: Duration,
) -> Option<u64> {
    let (provider, id) = model.split_once('/')?;
    let pi = std::env::split_paths(path)
        .map(|dir| dir.join("pi"))
        .find(|candidate| {
            std::fs::metadata(candidate)
                .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        })?;
    let output = crate::host::run_with(
        "node",
        "pi-registry-window",
        &[
            "--input-type=module",
            "--eval",
            PI_REGISTRY_WINDOW,
            "--",
            pi.to_str()?,
            provider,
            id,
        ],
        &[
            ("PATH", path),
            ("PI_OFFLINE", OsStr::new("1")),
            ("PI_CODING_AGENT_DIR", agent_dir.as_os_str()),
        ],
        None,
        bound,
    )
    .ok()?;
    String::from_utf8_lossy(&output.stdout)
        .trim_end_matches('\n')
        .parse::<u64>()
        .ok()
        .filter(|window| *window > 0)
}

/// The share of a Copilot session's window at which its CLI starts
/// compacting. Copilot has no switch that turns its automatic compaction
/// off, so a reading's point is this share of the window it names.
pub const COPILOT_COMPACTION_PCT: u64 = 80;

/// The capacity source the reading Copilot's context extension hands over
/// is recorded under: a record carrying another is no reading of the
/// extension's.
pub const COPILOT_EXTENSION_SOURCE: &str =
    "80% of tokenLimit, Copilot's backgroundCompactionThreshold default";

/// The reading Copilot's context extension hands over from one
/// `session.usage_info` event of the session's root agent, as `(tokens,
/// capacity)`: the tokens in the context, and [`COPILOT_COMPACTION_PCT`] of
/// the token limit rounded down, the point Copilot compacts at. `Err` names
/// the field that is no whole number, the limit also where it is 0.
pub fn copilot_usage(
    current_tokens: Option<&Value>,
    token_limit: Option<&Value>,
) -> Result<(u64, u64), &'static str> {
    let tokens = current_tokens
        .and_then(whole_number)
        .ok_or("current_tokens is no whole number")?;
    let limit = token_limit
        .and_then(whole_number)
        .filter(|limit| *limit > 0)
        .ok_or("token_limit is no whole number above 0")?;
    Ok((tokens, limit.saturating_mul(COPILOT_COMPACTION_PCT) / 100))
}

/// A whole number as Copilot writes one, an integer or a float with no
/// fraction: its CLI writes its telemetry counts as floats.
fn whole_number(value: &Value) -> Option<u64> {
    let number = value.as_number()?;
    if let Some(n) = number.as_u64() {
        return Some(n);
    }
    let f = number.as_f64()?;
    // A float with no fraction from 0 below `u64::MAX` converts exactly.
    (f >= 0.0 && f.fract() == 0.0 && f < u64::MAX as f64).then_some(f as u64)
}

/// The capacity source of a reading taken from a Copilot session's own
/// record, the `events.jsonl` its CLI writes in the session's folder.
pub const COPILOT_SESSION_SOURCE: &str =
    "80% of the token limit, from the Copilot session's own events.jsonl";

/// The window a read of a Copilot session's record takes first from its
/// end: the CLI writes a figure row at each tool call, so the last one
/// sits near the end.
const COPILOT_SESSION_FIRST: u64 = 65_536;

/// The most of a Copilot session's record a read takes from its end, the
/// window growing fourfold from [`COPILOT_SESSION_FIRST`] up to it: a turn
/// end and each controller tool call pay for the read, and a figure row
/// older than this many bytes of later rows is no reading of the session
/// now.
pub const COPILOT_SESSION_BOUND: u64 = 16 * TAIL_BYTES;

/// The context of the Copilot session `session` under the account
/// directory `home`, from the CLI's own record of it: the session's folder
/// found by its id ([`crate::session::fixed_id_file`]), its `events.jsonl`
/// read from the end. The reading is the last row in file order of the two
/// kinds that carry the CLI's own current count against its own limit: a
/// `tool.execution_complete` row's
/// `data.toolTelemetry.metrics.context_current_tokens` and
/// `context_token_limit`, and a `session.compaction_complete` row's
/// `data.postCompactionTokens` and `tokenLimit`, the count a compaction
/// left (measured on Copilot CLI 1.0.112). A compaction row whose
/// `data.success` is not `true` is passed over: a compaction that did not
/// succeed left the context as it was. Its window is the extension's,
/// [`copilot_usage`] taking both figures, so one session reads one window
/// from either source. A row of those kinds whose figures do not read is
/// passed over for the one before it. A `session.usage_record` row's
/// `inputTokens`, the prompt the provider counted for one call, is not
/// taken: the CLI judges its compaction on its own count, which runs above
/// and below that prompt (in a recorded 1.0.112 log, 760050 before calls
/// of 745020 to 746507, the compaction firing at 763743 by its own count,
/// then 44644 after a call of 45640). `Absent` where no folder, no
/// record or no such row stands within [`COPILOT_SESSION_BOUND`]; `Err`
/// where the id is outside the alphabet that keeps the path under its
/// directory, or the folder or record cannot be read.
pub fn copilot_session(home: &Path, session: &str) -> Result<Usage, String> {
    if !session_bound(session) {
        return Err("unbound".to_owned());
    }
    let folder = match crate::session::fixed_id_file(Harness::Copilot, home, Path::new(""), session)
    {
        Reading::Live(file) => file,
        Reading::Gone => return Ok(Usage::Absent),
        Reading::Unreadable { cause } => return Err(cause.to_owned()),
    };
    copilot_events(
        &folder.with_file_name("events.jsonl"),
        COPILOT_SESSION_BOUND,
    )
}

/// [`copilot_session`]'s read of the record at `path`, no further back from
/// its end than `bound` bytes.
fn copilot_events(path: &Path, bound: u64) -> Result<Usage, String> {
    let fail = |e: io::Error| format!("{}: {e}", path.display());
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Usage::Absent),
        Err(e) => return Err(fail(e)),
    };
    let len = file.metadata().map_err(fail)?.len();
    let mut window = COPILOT_SESSION_FIRST.min(bound);
    loop {
        // One byte before the window is read with it, so a line that starts
        // at the window's first byte is whole and only one that starts
        // before it is passed over.
        let from = len.saturating_sub(window.saturating_add(1));
        file.seek(SeekFrom::Start(from)).map_err(fail)?;
        let mut bytes = Vec::new();
        (&mut file)
            .take(len - from)
            .read_to_end(&mut bytes)
            .map_err(fail)?;
        let text = String::from_utf8_lossy(&bytes);
        let lines = if from == 0 {
            &text[..]
        } else {
            text.split_once('\n').map_or("", |(_, rest)| rest)
        };
        if let Some(usage) = lines.lines().rev().find_map(copilot_figure) {
            return Ok(usage);
        }
        if from == 0 || window >= bound {
            return Ok(Usage::Absent);
        }
        window = window.saturating_mul(4).min(bound);
    }
}

/// The reading one line of a Copilot session's record carries: `None` for
/// a line of any other kind, and for one of the two kinds whose figures do
/// not read.
fn copilot_figure(line: &str) -> Option<Usage> {
    const KINDS: [&str; 2] = [
        "\"tool.execution_complete\"",
        "\"session.compaction_complete\"",
    ];
    if !KINDS.iter().any(|kind| line.contains(kind)) {
        return None;
    }
    let Ok(Value::Object(row)) = serde_json::from_str::<Value>(line) else {
        return None;
    };
    let (tokens, window, model) = copilot_row_figure(&row)?;
    Some(Usage::Measured {
        tokens,
        window: Some(window),
        model,
    })
}

fn member<'v>(value: Option<&'v Value>, key: &str) -> Option<&'v Value> {
    value.and_then(|v| v.get(key))
}

/// [`copilot_figure`]'s reading of a parsed row: the tokens, the window
/// [`copilot_usage`] takes of the limit, and the model.
fn copilot_row_figure(row: &Map<String, Value>) -> Option<(u64, u64, String)> {
    let data = row.get("data");
    let (tokens, limit) = match word(row, "type") {
        "tool.execution_complete" => {
            let metrics = member(member(data, "toolTelemetry"), "metrics");
            (
                member(metrics, "context_current_tokens"),
                member(metrics, "context_token_limit"),
            )
        }
        "session.compaction_complete" => {
            if member(data, "success") != Some(&Value::Bool(true)) {
                return None;
            }
            (
                member(data, "postCompactionTokens"),
                member(data, "tokenLimit"),
            )
        }
        _ => return None,
    };
    let (tokens, window) = copilot_usage(tokens, limit).ok()?;
    let model = member(data, "model")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    Some((tokens, window, model))
}

/// The tokens one Copilot tool result adds to the context, as the CLI
/// counts them itself: a `tool.execution_complete` row's
/// `data.toolTelemetry.metrics.result_token_count`, a whole number
/// (measured on Copilot CLI 1.0.112). `None` where the row carries none.
pub fn copilot_result_tokens(row: &Map<String, Value>) -> Option<u64> {
    let metrics = member(member(row.get("data"), "toolTelemetry"), "metrics");
    member(metrics, "result_token_count").and_then(whole_number)
}

/// Whether `session` is spelled in the alphabet that keeps a path named by
/// it under its directory.
pub fn session_bound(session: &str) -> bool {
    !matches!(session, "" | "." | "..")
        && session
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// The capacity source of a reading taken from a session's status-line
/// record.
pub const COPILOT_STATUS_LINE_SOURCE: &str =
    "80% of context_window_size, from the Copilot statusLine session record";

/// The status-line record's refresh bound in seconds: a record older than
/// this is one the CLI stopped refreshing, which would read as a session
/// with room for as long as it stood.
pub const COPILOT_RECORD_MAX_AGE: u64 = 120;

/// A Copilot session's status-line record: the figures the CLI handed its
/// `statusLine` command, as `copilot-statusline` stored them under the
/// account directory, each `None` or empty where the CLI sent none or sent
/// a value of another type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopilotRecord {
    pub tokens: Option<u64>,
    /// The whole window, before the compaction share is taken of it.
    pub window: Option<u64>,
    pub model: String,
    pub allow_all: Option<bool>,
}

/// The status-line record of `session` under the account directory `home`,
/// answered only where every binding it holds agrees: its own session id,
/// its account directory, the folder that holds `transcript` where it names
/// one (the CLI hands its status line the session's folder, and the turn
/// end the `events.jsonl` inside it), and a stamp no more than
/// [`COPILOT_RECORD_MAX_AGE`] seconds before `now` and none after it. `Err`
/// names the first binding that did not agree:
/// `unbound` (a session id outside the alphabet that keeps the path under
/// its directory), `missing`, `unreadable` (no record of this form),
/// `wrong-session`, `wrong-account`, `wrong-transcript`, `stale`.
pub fn copilot_record(
    home: &Path,
    session: &str,
    transcript: &str,
    now: u64,
) -> Result<CopilotRecord, &'static str> {
    if !session_bound(session) {
        return Err("unbound");
    }
    let path = home.join("lane-status").join(format!("{session}.json"));
    if !std::fs::metadata(&path).is_ok_and(|meta| meta.is_file()) {
        return Err("missing");
    }
    let text = std::fs::read_to_string(&path).map_err(|_| "unreadable")?;
    let Ok(Value::Object(record)) = serde_json::from_str::<Value>(&text) else {
        return Err("unreadable");
    };
    let (Some(recorded), Some(account), Some(written)) = (
        record.get("session_id").and_then(Value::as_str),
        record.get("copilot_home").and_then(Value::as_str),
        record.get("written_at").and_then(Value::as_f64),
    ) else {
        return Err("unreadable");
    };
    if recorded != session {
        return Err("wrong-session");
    }
    if home.to_str() != Some(account) {
        return Err("wrong-account");
    }
    let folder = Path::new(transcript).parent().map(Path::as_os_str);
    if !transcript.is_empty() && folder != Some(OsStr::new(word(&record, "transcript_path"))) {
        return Err("wrong-transcript");
    }
    let age = now as f64 - written.floor();
    if !(0.0..=COPILOT_RECORD_MAX_AGE as f64).contains(&age) {
        return Err("stale");
    }
    let status = record.get("status").unwrap_or(&Value::Null);
    let whole = |value: &Value| {
        value
            .as_f64()
            .filter(|n| *n >= 0.0)
            .map(|n| n.floor() as u64)
    };
    Ok(CopilotRecord {
        tokens: whole(&status["context_window"]["current_context_tokens"]),
        window: whole(&status["context_window"]["context_window_size"]),
        model: status["model"]["id"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
        allow_all: status["allow_all_enabled"].as_bool(),
    })
}

impl CopilotRecord {
    /// The reading the record gives: its tokens judged against the share of
    /// its window Copilot compacts at; `Unread` where it carries no token
    /// count, which is never read as zero.
    pub fn usage(&self) -> Usage {
        match self.tokens {
            None => Usage::Unread,
            Some(tokens) => Usage::Measured {
                tokens,
                window: self
                    .window
                    .map(|w| w.saturating_mul(COPILOT_COMPACTION_PCT) / 100),
                model: self.model.clone(),
            },
        }
    }

    /// The stop the record establishes for a session whose launch
    /// `granted` the allow-all mode: `allow-all-blocked-by-policy` where
    /// the CLI reports it off. Enterprise managed settings can withdraw the
    /// grant mid-run, and every tool call then waits on a prompt nobody at
    /// the pane answers; a launch without the grant reports it off by
    /// design, so it names none.
    pub fn stop_cause(&self, granted: bool) -> Option<&'static str> {
        (granted && self.allow_all == Some(false)).then_some("allow-all-blocked-by-policy")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn measured(tokens: u64, window: Option<u64>, model: &str) -> Usage {
        Usage::Measured {
            tokens,
            window,
            model: model.to_owned(),
        }
    }

    /// A Claude Code assistant line as the released fixtures write it.
    fn claude_line(model: &str, tokens: u64) -> String {
        format!(
            r#"{{"type":"assistant","message":{{"model":"{model}","usage":{{"input_tokens":1,"cache_read_input_tokens":{},"cache_creation_input_tokens":0,"output_tokens":7}}}}}}"#,
            tokens - 8
        )
    }

    fn codex_context(model: &str) -> String {
        format!(r#"{{"type":"turn_context","payload":{{"model":"{model}"}}}}"#)
    }

    fn codex_count(tokens: u64, window: u64) -> String {
        format!(
            r#"{{"type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":{},"output_tokens":7,"total_tokens":{tokens}}},"model_context_window":{window}}}}}}}"#,
            tokens - 7
        )
    }

    #[test]
    fn a_claude_transcript_reads_its_last_usage_line_and_names_its_usable_window() {
        let two = [
            claude_line("claude-opus-5-5", 1000),
            "not json".to_owned(),
            claude_line("claude-opus-5-5", 300_000),
            r#"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#.to_owned(),
        ]
        .join("\n");
        let rows: [(&str, bool, Usage); 5] = [
            (
                &two,
                true,
                measured(300_000, Some(1_000_000), "claude-opus-5-5"),
            ),
            (
                &two,
                false,
                measured(300_000, Some(967_000), "claude-opus-5-5"),
            ),
            (
                r#"{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"prompt_tokens":5}}}"#,
                true,
                Usage::Unread,
            ),
            (
                r#"{"type":"user","message":{"content":"hi"}}"#,
                true,
                Usage::Absent,
            ),
            ("", true, Usage::Absent),
        ];
        for (text, off, want) in rows {
            assert_eq!(claude(text, off), Ok(want), "{text}");
        }
        assert!(claude(r#"{"message":{"usage":{"input_tokens":"many"}}}"#, true).is_err());
    }

    #[test]
    fn a_codex_rollout_names_its_window_only_where_no_compaction_fires_below_it() {
        let last = [
            codex_context("gpt-6-astra"),
            codex_count(1000, 258_400),
            codex_count(232_560, 258_400),
        ]
        .join("\n");
        let null_info = [
            codex_context("gpt-6-astra"),
            codex_count(1000, 258_400),
            r#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#.to_owned(),
        ]
        .join("\n");
        let unread = [
            codex_context("gpt-6-astra"),
            r#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{},"model_context_window":258400}}}"#.to_owned(),
        ]
        .join("\n");
        let rows: [(&str, Option<u64>, Usage); 7] = [
            (
                &last,
                Some(u64::MAX),
                measured(232_560, Some(258_400), "gpt-6-astra"),
            ),
            (
                &last,
                Some(258_400),
                measured(232_560, Some(258_400), "gpt-6-astra"),
            ),
            (&last, Some(258_399), measured(232_560, None, "gpt-6-astra")),
            (&last, None, measured(232_560, None, "gpt-6-astra")),
            (
                &null_info,
                Some(u64::MAX),
                measured(1000, Some(258_400), "gpt-6-astra"),
            ),
            (&unread, Some(u64::MAX), Usage::Unread),
            (&codex_context("gpt-6-astra"), Some(u64::MAX), Usage::Absent),
        ];
        for (text, floor, want) in rows {
            assert_eq!(codex(text, floor), Ok(want), "{text} {floor:?}");
        }
    }

    /// The launch's recorded overrides over the home's config.toml, each row
    /// one session: a launched one (`Some`, empty where its command carried
    /// no compaction words) or one started by hand (`None`).
    #[test]
    fn a_codex_floor_takes_the_launch_overrides_over_the_home_config() {
        const MAX: &str = "9223372036854775807";
        let flags = |settings: &str| format!(r#"{{"harness":"codex","settings":{{{settings}}}}}"#);
        let off = flags(&format!(
            r#""model_auto_compact_token_limit":"{MAX}","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0""#
        ));
        let keys = format!(
            "model_auto_compact_token_limit = {MAX}\nmodel_auto_compact_token_limit_scope = \"body_after_prefix\"\nmodel_post_turn_compact_threshold_percent = 0\n"
        );
        let total = keys.replace("body_after_prefix", "total");
        let max = Some(9_223_372_036_854_775_807);
        // The row, the launch overrides, the config body, the floor.
        type Row = (&'static str, Option<String>, Option<String>, Option<u64>);
        let rows: Vec<Row> = vec![
            ("launch override alone", Some(off.clone()), None, max),
            (
                "launch override as numbers",
                Some(flags(
                    r#""model_auto_compact_token_limit":258400,"model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":0"#,
                )),
                None,
                Some(258_400),
            ),
            (
                "hand-started, config keeps compaction past",
                None,
                Some(keys.clone()),
                max,
            ),
            (
                "hand-started, quoted limit",
                None,
                Some(keys.replace(&format!("= {MAX}"), "= \"300000\"")),
                Some(300_000),
            ),
            ("hand-started, no config", None, None, None),
            ("hand-started, total scope", None, Some(total.clone()), None),
            (
                "hand-started, post-turn compaction on",
                None,
                Some(keys.replace("percent = 0", "percent = 80")),
                None,
            ),
            (
                "hand-started, post-turn threshold unset",
                None,
                Some(keys.replace("model_post_turn_compact_threshold_percent = 0\n", "")),
                None,
            ),
            (
                "hand-started, limit unset",
                None,
                Some(keys.replace(&format!("model_auto_compact_token_limit = {MAX}\n"), "")),
                None,
            ),
            (
                "hand-started, limit with digit separators",
                None,
                Some(keys.replace(&format!("= {MAX}"), "= 300_000")),
                None,
            ),
            (
                "hand-started, keys under a table",
                None,
                Some(format!("[projects.\"/w\"]\n{keys}")),
                None,
            ),
            (
                "hand-started, background compaction on",
                None,
                Some(format!("{keys}[features]\nasync_compaction = true\n")),
                None,
            ),
            (
                "hand-started, background compaction table on",
                None,
                Some(format!(
                    "{keys}[features.async_compaction]\nenabled = true\n"
                )),
                None,
            ),
            (
                "hand-started, background compaction off",
                None,
                Some(format!(
                    "{keys}[features.async_compaction] # background\nenabled = false\n"
                )),
                max,
            ),
            (
                "hand-started, commented header turns background compaction on",
                None,
                Some(format!(
                    "{keys}[features] # background compaction\nasync_compaction = true\n"
                )),
                None,
            ),
            (
                "hand-started, root dotted switch on",
                None,
                Some(format!("features.async_compaction = true\n{keys}")),
                None,
            ),
            (
                "hand-started, selected profile turns background compaction on",
                None,
                Some(format!(
                    "profile = \"p\"\n{keys}[profiles.p.features]\nasync_compaction = true\n"
                )),
                None,
            ),
            (
                "launch with no compaction words reads the config",
                Some(String::new()),
                Some(keys.clone()),
                max,
            ),
            (
                "launch scope over the config's",
                Some(flags(r#""model_auto_compact_token_limit_scope":"total""#)),
                Some(keys.clone()),
                None,
            ),
            (
                "launch limit over the config's",
                Some(flags(r#""model_auto_compact_token_limit":"300000""#)),
                Some(keys.clone()),
                Some(300_000),
            ),
            (
                "launch override completes the config",
                Some(flags(
                    r#""model_auto_compact_token_limit_scope":"body_after_prefix""#,
                )),
                Some(total),
                max,
            ),
            (
                "override not JSON",
                Some("not-json".to_owned()),
                Some(keys.clone()),
                None,
            ),
            (
                "override an array",
                Some("[]".to_owned()),
                Some(keys.clone()),
                None,
            ),
            (
                "override settings not an object",
                Some(r#"{"harness":"codex","settings":false}"#.to_owned()),
                Some(keys.clone()),
                None,
            ),
            (
                "override of another harness",
                Some(r#"{"harness":"claude","settings":{}}"#.to_owned()),
                Some(keys),
                None,
            ),
        ];
        for (row, overrides, body, want) in rows {
            let dir = tempfile::tempdir().unwrap();
            let config = dir.path().join("config.toml");
            if let Some(body) = body {
                std::fs::write(&config, body).unwrap();
            }
            assert_eq!(
                codex_compaction_floor(overrides.as_deref(), &config),
                Ok(want),
                "{row}"
            );
        }
        let dir = tempfile::tempdir().unwrap();
        let config = dir.path().join("config.toml");
        std::fs::create_dir(&config).unwrap();
        let unread = codex_compaction_floor(Some(&off), &config).unwrap_err();
        assert_eq!(unread.file, config);
    }

    #[test]
    fn a_pi_session_file_names_its_provider_and_takes_a_window_only_with_compaction_off() {
        let line = r#"{"type":"message","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-5-5","usage":{"input":100,"output":8,"cacheRead":146000,"cacheWrite":0}}}"#;
        let found = |model: &str| (model == "anthropic/claude-opus-5-5").then_some(200_000);
        assert_eq!(
            pi(line, true, found),
            Ok(measured(
                146_108,
                Some(200_000),
                "anthropic/claude-opus-5-5"
            ))
        );
        assert_eq!(
            pi(line, false, found),
            Ok(measured(146_108, None, "anthropic/claude-opus-5-5"))
        );
        let claude_spelled =
            r#"{"message":{"model":"claude-opus-5-5","usage":{"input_tokens":5}}}"#;
        assert_eq!(pi(claude_spelled, true, found), Ok(Usage::Unread));
    }

    /// pi-codex-bridge's placeholder on a message ending in a tool call
    /// counts nothing and still names its model: the live reading keeps
    /// the count before it only where that count is the same model's, and
    /// `session model` names the placeholder's model.
    #[test]
    fn a_pi_placeholder_response_keeps_its_model_and_no_other_models_count() {
        let anthropic = r#"{"type":"message","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-5-5","usage":{"input":100,"output":8,"cacheRead":146000,"cacheWrite":0}}}"#;
        let codex = r#"{"type":"message","message":{"role":"assistant","provider":"pi-codex","model":"gpt-5.5","usage":{"input":60,"output":12,"cacheRead":10600,"cacheWrite":0}}}"#;
        let placeholder = r#"{"type":"message","message":{"role":"assistant","provider":"pi-codex","model":"gpt-5.5","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0}}}"#;
        let rows = [
            (
                "a switch to pi-codex",
                [anthropic, placeholder].join("\n"),
                Usage::Unread,
            ),
            (
                "pi-codex before it",
                [codex, placeholder].join("\n"),
                measured(10_672, None, "pi-codex/gpt-5.5"),
            ),
        ];
        let root = tempfile::tempdir().unwrap();
        for (name, text, usage) in rows {
            assert_eq!(pi(&text, false, |_| None), Ok(usage), "{name}");
            let file = root.path().join("pi.jsonl");
            std::fs::write(&file, &text).unwrap();
            let now = session_now(
                &SessionAt {
                    harness: Harness::Pi,
                    session: "p1",
                    transcript: Some(&file),
                    home: None,
                    cwd: root.path(),
                    now: 0,
                },
                Some("launch/model"),
                None,
            );
            assert_eq!(
                now.model,
                Ok(Member::Session("pi-codex/gpt-5.5".to_owned())),
                "{name}"
            );
        }
    }

    #[test]
    fn pi_compacts_unless_the_user_turns_it_off_and_the_project_does_not_turn_it_on() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path();
        let file = |name: &str, body: Option<&str>| {
            let path = dir.join(name);
            if let Some(body) = body {
                std::fs::write(&path, body).unwrap();
            }
            path
        };
        let off = Some(r#"{"compaction":{"enabled":false}}"#);
        let on = Some(r#"{"compaction":{"enabled":true}}"#);
        let rows = [
            (None, None, true),
            (off, None, false),
            (off, Some("{}"), false),
            (off, Some(r#"{"compaction":{"enabled":false}}"#), false),
            (off, on, true),
            (on, Some(r#"{"compaction":{"enabled":false}}"#), true),
        ];
        for (n, (user, project, want)) in rows.into_iter().enumerate() {
            let user = file(&format!("user-{n}.json"), user);
            let project = file(&format!("project-{n}.json"), project);
            assert_eq!(pi_compaction_on(&user, &project), Ok(want), "row {n}");
        }
        let broken = file("broken.json", Some("{"));
        let unread = pi_compaction_on(&broken, &dir.join("absent.json")).unwrap_err();
        assert_eq!(unread.file, broken);
    }

    #[test]
    fn a_long_transcript_is_read_from_its_tail_then_whole_where_the_tail_holds_no_usage() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path();
        let path = dir.join("t.jsonl");
        let filler = format!(
            r#"{{"type":"user","message":{{"content":"{}"}}}}"#,
            "x".repeat(4096)
        );
        let mut text = claude_line("claude-opus-5-5", 1000);
        for _ in 0..300 {
            text.push('\n');
            text.push_str(&filler);
        }
        std::fs::write(&path, &text).unwrap();
        assert_eq!(
            read_file(&path, |t| claude(t, false)),
            Ok(measured(1000, Some(967_000), "claude-opus-5-5"))
        );
        text.push('\n');
        text.push_str(&claude_line("claude-opus-5-5", 5000));
        std::fs::write(&path, &text).unwrap();
        assert_eq!(
            read_file(&path, |t| claude(t, false)),
            Ok(measured(5000, Some(967_000), "claude-opus-5-5"))
        );
        assert!(read_file(&dir.join("absent"), |t| claude(t, false)).is_err());
    }

    /// A rollout in the shape measured on Codex 0.167.2: its one
    /// `turn_context`, naming `gpt-6.1-sol` at effort `high`, is its tenth
    /// line, some 130 KB in, and four megabytes of other lines follow it,
    /// the last token count, 264,601 tokens, among them.
    fn measured_rollout() -> String {
        let pad = |kind: &str, n: usize| {
            format!(
                r#"{{"type":"{kind}","payload":{{"text":"{}"}}}}"#,
                "x".repeat(n)
            )
        };
        let mut lines =
            vec![r#"{"type":"session_meta","payload":{"id":"s1","cwd":"/w"}}"#.to_owned()];
        lines.extend((0..8).map(|_| pad("response_item", 16_400)));
        lines.push(r#"{"type":"turn_context","payload":{"approval_policy":"never","cwd":"/w","effort":"high","model":"gpt-6.1-sol","summary":"auto","turn_id":"t1"}}"#.to_owned());
        let kinds = [
            "event_msg",
            "response_item",
            "token_usage_record",
            "inter_agent_communication_metadata",
            "world_state",
        ];
        lines.extend((0..1000).map(|n| pad(kinds[n % kinds.len()], 4096)));
        lines.push(codex_count(264_601, 400_000));
        lines.push(pad("event_msg", 4096));
        let text = lines.join("\n");
        let at = text.find(r#""turn_context""#).unwrap() as u64;
        assert!(
            at + TAIL_BYTES < text.len() as u64,
            "the turn context lies before the tail"
        );
        text
    }

    #[test]
    fn a_rollout_whose_one_turn_context_lies_before_its_tail_names_that_model() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("rollout.jsonl");
        std::fs::write(&path, measured_rollout()).unwrap();
        assert_eq!(
            read_file(&path, |t| codex(t, None)),
            Ok(measured(264_601, None, "gpt-6.1-sol"))
        );
    }

    /// The turn reading takes each member from the last `turn_context` that
    /// names it, before the tail as well as in it.
    #[test]
    fn a_codex_turn_names_the_model_and_effort_its_turn_context_names() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("rollout.jsonl");
        let mut switched = measured_rollout();
        switched.push('\n');
        switched.push_str(
            r#"{"type":"turn_context","payload":{"effort":"xhigh","model":"gpt-6.1-astra"}}"#,
        );
        let turn = |model: &str, effort: &str| Named {
            model: model.to_owned(),
            effort: effort.to_owned(),
        };
        let rows = [
            (measured_rollout(), turn("gpt-6.1-sol", "high")),
            (switched, turn("gpt-6.1-astra", "xhigh")),
            (codex_count(1000, 258_400), turn("", "")),
        ];
        for (text, want) in rows {
            std::fs::write(&path, &text).unwrap();
            assert_eq!(codex_turn(&path), Ok(want));
        }
        assert!(codex_turn(&root.path().join("absent")).is_err());
    }

    /// A status-line record in the form `copilot-statusline` writes it under
    /// the account `home` for `s1`, stamped `written`.
    fn status_record(home: &Path, written: Value, status: Value) -> Value {
        serde_json::json!({"session_id": "s1", "transcript_path": "/t/s1",
            "copilot_home": home.display().to_string(), "written_at": written, "status": status})
    }

    /// The extension's figures are taken only as whole numbers, a float with
    /// no fraction among them, and the limit only above 0: a fraction, a
    /// negative figure, a string or a missing field is never read as a
    /// reading.
    #[test]
    fn a_copilot_usage_reading_takes_whole_figures_and_a_limit_above_zero() {
        fn present(value: &Value) -> Option<&Value> {
            (!value.is_null()).then_some(value)
        }
        let tokens_gap = Err("current_tokens is no whole number");
        let limit_gap = Err("token_limit is no whole number above 0");
        let rows = [
            (serde_json::json!(0), serde_json::json!(1001), Ok((0, 800))),
            (
                serde_json::json!(5.0),
                serde_json::json!(1000.0),
                Ok((5, 800)),
            ),
            (serde_json::json!(5.5), serde_json::json!(1000), tokens_gap),
            (serde_json::json!(-1), serde_json::json!(1000), tokens_gap),
            (serde_json::json!("5"), serde_json::json!(1000), tokens_gap),
            (Value::Null, serde_json::json!(1000), tokens_gap),
            (serde_json::json!(5), serde_json::json!(0), limit_gap),
            (serde_json::json!(5), serde_json::json!(0.5), limit_gap),
            (serde_json::json!(5), Value::Null, limit_gap),
        ];
        for (tokens, limit, want) in rows {
            let row = format!("{tokens} {limit}");
            assert_eq!(
                copilot_usage(present(&tokens), present(&limit)),
                want,
                "{row}"
            );
        }
    }

    #[test]
    fn a_copilot_status_line_record_answers_only_where_every_binding_agrees() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("account");
        let file = home.join("lane-status").join("s1.json");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        let now = 1_000_000;
        let status = serde_json::json!({"session_id": "s1", "model": {"id": "claude-opus-5"},
            "context_window": {"current_context_tokens": 400_000.7, "context_window_size": 1_000_000},
            "allow_all_enabled": false});
        let read =
            |session: &str, transcript: &str| copilot_record(&home, session, transcript, now);
        assert_eq!(read("s1", ""), Err("missing"));
        assert_eq!(read("..", ""), Err("unbound"));
        assert_eq!(read("s/1", ""), Err("unbound"));
        let fresh = status_record(&home, Value::from(now - 120), status.clone());
        let with = |key: &str, value: &str| {
            let mut record = fresh.clone();
            record[key] = Value::from(value);
            record.to_string()
        };
        let rows: &[(String, &str, Result<(), &str>)] = &[
            ("not json".to_owned(), "", Err("unreadable")),
            (
                serde_json::json!({"session_id": "s1"}).to_string(),
                "",
                Err("unreadable"),
            ),
            (fresh.to_string(), "", Ok(())),
            (fresh.to_string(), "/t/s1/events.jsonl", Ok(())),
            (
                fresh.to_string(),
                "/t/s2/events.jsonl",
                Err("wrong-transcript"),
            ),
            (with("written_at", "1000000"), "", Err("unreadable")),
            (with("session_id", "s2"), "", Err("wrong-session")),
            (with("copilot_home", "/other"), "", Err("wrong-account")),
            (
                status_record(&home, Value::from(now - 121), status.clone()).to_string(),
                "",
                Err("stale"),
            ),
            (
                status_record(&home, Value::from(now + 1), status.clone()).to_string(),
                "",
                Err("stale"),
            ),
        ];
        for (text, transcript, want) in rows {
            std::fs::write(&file, text).unwrap();
            assert_eq!(
                read("s1", transcript).map(|_| ()),
                *want,
                "{text} {transcript}"
            );
        }
        std::fs::write(&file, fresh.to_string()).unwrap();
        let mode = |bits| std::fs::set_permissions(&file, std::fs::Permissions::from_mode(bits));
        mode(0o000).unwrap();
        assert_eq!(
            read("s1", ""),
            Err("unreadable"),
            "a record that cannot be read"
        );
        mode(0o600).unwrap();
        let record = read("s1", "").unwrap();
        assert_eq!(
            record.usage(),
            measured(400_000, Some(800_000), "claude-opus-5")
        );
        assert_eq!(record.stop_cause(true), Some("allow-all-blocked-by-policy"));
        assert_eq!(record.stop_cause(false), None);
        let bare = status_record(
            &home,
            Value::from(now),
            serde_json::json!({"context_window": {"current_context_tokens": "9"}}),
        );
        std::fs::write(&file, bare.to_string()).unwrap();
        let record = read("s1", "").unwrap();
        assert_eq!(record.usage(), Usage::Unread);
        assert_eq!(record.stop_cause(true), None);
    }

    /// Rows of a Copilot CLI 1.0.112 session's `events.jsonl` in file order,
    /// every id made up and every text a placeholder: a session start, a
    /// first tool row at 35,971, a turn end, a tool row at 51,958, a tool row
    /// with no telemetry and an attached agent's with no context figure, the
    /// compaction whole (a tool row at 760,050, its start, three usage
    /// records, its completion at 44,648, a usage record), a tool row at
    /// 44,644 and three usage records after it, the CLI's limit 952,000.
    const COPILOT_EVENTS: &str = include_str!("../../tests/rust/fixtures/copilot-events.jsonl");

    /// The fixture's first `rows` lines, each line ended.
    fn copilot_rows(rows: usize) -> String {
        COPILOT_EVENTS
            .lines()
            .take(rows)
            .map(|line| format!("{line}\n"))
            .collect()
    }

    /// A session reads the CLI's own count at its last tool row, or the
    /// count a later compaction left, against the extension's share of the
    /// CLI's limit; a tool row with no figure, or a compaction that did not
    /// succeed, is passed over for the row before it, and the usage records'
    /// prompt figures are never taken. A
    /// record with no figure row, or no record, is no reading; one that
    /// cannot be read, or an id outside its alphabet, is an error.
    #[test]
    fn a_copilot_session_reads_its_last_context_figure_from_its_own_record() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let folder = home.join("session-state").join("c1");
        let read = || copilot_session(home, "c1");
        assert_eq!(read(), Ok(Usage::Absent), "no folder");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("workspace.yaml"), "id: c1\ncwd: /w\n").unwrap();
        assert_eq!(read(), Ok(Usage::Absent), "no record");
        let model = "claude-opus-5.5";
        let rows = [
            (18, measured(44_644, Some(761_600), model)),
            (13, measured(44_648, Some(761_600), "")),
            (8, measured(760_050, Some(761_600), model)),
            (7, measured(51_958, Some(761_600), model)),
            (2, Usage::Absent),
            (0, Usage::Absent),
        ];
        let events = folder.join("events.jsonl");
        for (count, want) in rows {
            std::fs::write(&events, copilot_rows(count)).unwrap();
            assert_eq!(read(), Ok(want), "the first {count} rows");
        }
        // The fixture's compaction row, planted here as one that did not
        // succeed, after the rows before it.
        let compaction = COPILOT_EVENTS.lines().nth(12).unwrap();
        let failed = compaction.replacen(r#""success":true"#, r#""success":false"#, 1);
        assert_ne!(failed, compaction);
        std::fs::write(&events, format!("{}{failed}\n", copilot_rows(12))).unwrap();
        assert_eq!(
            read(),
            Ok(measured(760_050, Some(761_600), model)),
            "a compaction that did not succeed"
        );
        assert_eq!(copilot_session(home, ".."), Err("unbound".to_owned()));
        std::fs::set_permissions(&events, std::fs::Permissions::from_mode(0o000)).unwrap();
        assert!(read().is_err(), "a record that cannot be read");
    }

    /// The record is read from its end in a window that grows up to the
    /// bound: a figure row followed by a long run of other rows is found
    /// while it lies inside the bound and is no reading past it, and a line
    /// starting at the window's first byte is read whole.
    #[test]
    fn a_copilot_record_is_read_from_its_end_no_further_back_than_its_bound() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("events.jsonl");
        let lines: Vec<&str> = COPILOT_EVENTS.lines().collect();
        let (figure, other) = (lines[14], lines[15]);
        let found = measured(44_644, Some(761_600), "claude-opus-5.5");
        let after = |count: usize| {
            let mut text = format!("{figure}\n");
            for _ in 0..count {
                text.push_str(other);
                text.push('\n');
            }
            text
        };
        let other_bytes = other.len() as u64 + 1;
        let inside = (3 * COPILOT_SESSION_FIRST / other_bytes) as usize;
        let past = (TAIL_BYTES / other_bytes) as usize + 1;
        let rows = [(inside, found.clone()), (past, Usage::Absent)];
        for (count, want) in rows {
            std::fs::write(&path, after(count)).unwrap();
            assert_eq!(
                copilot_events(&path, TAIL_BYTES),
                Ok(want),
                "{count} rows after"
            );
        }
        // The figure row starts at the first window's first byte, then one
        // byte before it.
        let pad = |len: usize| format!(r#"{{"type":"x","data":"{}"}}"#, "x".repeat(len - 22));
        let tail = COPILOT_SESSION_FIRST as usize - figure.len() - 1;
        let rows = [(tail, found), (tail + 1, Usage::Absent)];
        for (tail, want) in rows {
            let text = format!("{other}\n{figure}\n{}\n", pad(tail - 1));
            std::fs::write(&path, &text).unwrap();
            assert_eq!(
                copilot_events(&path, COPILOT_SESSION_FIRST),
                Ok(want),
                "{tail} bytes after the figure row"
            );
        }
    }

    /// `pi` and `node` stand-ins in `dir`, in the contract the released
    /// suite's stub install fixes: `node` is handed the `pi` on the path,
    /// the provider and the id, offline, under the Pi user directory
    /// `agent`, and prints the registry's window as one whole number, here
    /// `answer`'s, for `anthropic/claude-opus-5-5` alone.
    fn registry_stand_ins(dir: &Path, agent: &Path, answer: &str) {
        std::fs::create_dir_all(dir).unwrap();
        let pi = dir.join("pi");
        let node = format!(
            "#!/bin/sh\nfor a; do p3=$p2; p2=$p1; p1=$a; done\n[ \"$p3\" = '{}' ] && [ \"$p2\" = anthropic ] && [ \"$p1\" = claude-opus-5-5 ] && [ \"$PI_OFFLINE\" = 1 ] && [ \"$PI_CODING_AGENT_DIR\" = '{}' ] && {answer}\nexit 0\n",
            pi.display(),
            agent.display()
        );
        crate::host::write_executable(&pi, "#!/bin/sh\nexit 0\n");
        crate::host::write_executable(&dir.join("node"), node);
    }

    #[test]
    fn pis_registry_window_is_the_answer_of_node_over_the_pi_on_the_path() {
        let dir = tempfile::tempdir().unwrap();
        let agent = dir.path().join("agent");
        let bin = dir.path().join("bin");
        let model = "anthropic/claude-opus-5-5";
        let window = |asked: &str, bound: Duration| {
            pi_registry_window(asked, &agent, bin.as_os_str(), bound)
        };
        let bound = Duration::from_secs(5);
        let rows: &[(&str, &str, Option<u64>)] = &[
            ("echo 1000000", model, Some(1_000_000)),
            ("echo 1000000", "claude-opus-5-5", None),
            ("echo 0", model, None),
            ("echo 1e6", model, None),
            ("true", model, None),
        ];
        for (answer, asked, want) in rows {
            registry_stand_ins(&bin, &agent, answer);
            assert_eq!(window(asked, bound), *want, "{answer} {asked}");
        }
        // With no `pi` on the path no `node` runs, even one that would answer.
        registry_stand_ins(&bin, &agent, "echo 1000000");
        crate::host::write_executable(&bin.join("node"), "#!/bin/sh\necho 1000000\n");
        std::fs::remove_file(bin.join("pi")).unwrap();
        assert_eq!(window(model, bound), None, "no pi");
        registry_stand_ins(&bin, &agent, "echo 1000000");
        std::fs::remove_file(bin.join("node")).unwrap();
        assert_eq!(window(model, bound), None, "no node");
        // A registry that would answer only after the bound is stopped there.
        // The path the read is handed holds the stand-ins alone, so the pause
        // names its program by its own path.
        let sleep = ["/bin/sleep", "/usr/bin/sleep"]
            .into_iter()
            .find(|p| Path::new(p).is_file())
            .expect("a sleep program");
        registry_stand_ins(&bin, &agent, &format!("{sleep} 2 && echo 1000000"));
        assert_eq!(
            window(model, Duration::from_millis(300)),
            None,
            "past the bound"
        );
    }
}
