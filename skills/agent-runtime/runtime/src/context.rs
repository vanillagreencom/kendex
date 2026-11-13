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
/// carrying a usage object. Its window is the model's declared capacity
/// ([`Harness::context_capacity`]) only where `compaction_off`: enabled
/// compaction has inputs this reader does not see, so its point stays
/// unresolved.
pub fn claude(text: &str, compaction_off: bool) -> Result<Usage, String> {
    let mut last = Usage::Absent;
    for line in objects(text) {
        let Some(Value::Object(message)) = line.get("message") else {
            continue;
        };
        let Some(Value::Object(usage)) = message.get("usage") else {
            continue;
        };
        if message.get("model").and_then(Value::as_str) == Some(CLAUDE_SYNTHETIC) {
            continue;
        }
        last = if CLAUDE_FIELDS.iter().any(|f| usage.contains_key(*f)) {
            let model = word(message, "model").to_owned();
            Usage::Measured {
                tokens: summed(usage, &CLAUDE_FIELDS)?,
                window: compaction_off
                    .then(|| Harness::Claude.context_capacity(&model))
                    .flatten(),
                model,
            }
        } else {
            Usage::Unread
        };
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
/// `overrides`, the launch's compaction overrides as the caller recorded
/// them, are Codex's and keep every compaction at or past that window
/// (`body_after_prefix` scope, post-turn compaction off, a token limit no
/// smaller than the window); any other evidence, or none, leaves the point
/// unresolved and never discards the count.
pub fn codex(text: &str, overrides: Option<&str>) -> Result<Usage, String> {
    let mut turn = Named::default();
    let mut last: Option<Option<(u64, Option<u64>)>> = None;
    for line in objects(text) {
        let payload = line.get("payload");
        match word(&line, "type") {
            "turn_context" => turn.take_turn(payload),
            "event_msg" => {
                let Some(payload) = payload else { continue };
                if payload.get("type").and_then(Value::as_str) != Some("token_count") {
                    continue;
                }
                let Some(Value::Object(info)) = payload.get("info") else {
                    continue;
                };
                let total = info
                    .get("last_token_usage")
                    .and_then(|u| u.get("total_tokens"))
                    .and_then(Value::as_u64);
                last = Some(total.map(|tokens| {
                    let window = info.get("model_context_window").and_then(Value::as_u64);
                    (
                        tokens,
                        window.filter(|w| codex_point_verified(overrides, *w)),
                    )
                }));
            }
            _ => {}
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
pub struct SessionAt<'a> {
    pub harness: Harness,
    pub session: &'a str,
    pub transcript: Option<&'a Path>,
    pub home: Option<&'a Path>,
    pub cwd: &'a Path,
    pub now: u64,
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

/// The model and the effort a session runs on now, each its own answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Now {
    pub model: Result<Member, RecordUnread>,
    pub effort: Result<Member, RecordUnread>,
}

/// Whether `harness`'s own session record is measured to carry the effort:
/// a Codex `turn_context` does. Claude Code's transcript, Copilot CLI's
/// status-line record and Pi's session file are not, so their effort is the
/// launch's declaration alone.
fn effort_recorded(harness: Harness) -> bool {
    match harness {
        Harness::Codex => true,
        Harness::Claude | Harness::Copilot | Harness::Pi => false,
    }
}

/// What `session model` answers for the session `at` names: each member
/// from the session's own record first, and from the launch's
/// `declared_model` or `declared_effort` only where that record names none.
/// A member the record cannot be read for is that failure.
pub fn session_now(
    at: &SessionAt,
    declared_model: Option<&str>,
    declared_effort: Option<&str>,
) -> Now {
    let named = session_named(at);
    let effort = match &named {
        Err(unread) if effort_recorded(at.harness) => Err(unread.clone()),
        Ok(named) if effort_recorded(at.harness) => Ok(Member::of(&named.effort, declared_effort)),
        Ok(_) | Err(_) => Ok(Member::of("", declared_effort)),
    };
    Now {
        model: named.map(|named| Member::of(&named.model, declared_model)),
        effort,
    }
}

impl Now {
    /// The two lines `session model` prints, model first: `<member>=<value>
    /// source=session|launch`, `session-<member>-unrecorded harness=
    /// session=` where neither names it, or the read's own key with the
    /// harness, the session and its cause.
    pub fn lines(&self, harness: Harness, session: &str) -> [String; 2] {
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
        [line("model", &self.model), line("effort", &self.effort)]
    }

    /// 0 where both members answer, 1 where one is unrecorded by name, 2
    /// where a read failed: a refusal and an unknown are different answers.
    pub fn exit_code(&self) -> i32 {
        let answers = [&self.model, &self.effort];
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
        Harness::Pi => read_file(&file()?, |text| pi(text, false, |_| None))
            .map(model)
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

/// Whether Codex launched under `overrides` compacts no earlier than
/// `window`.
fn codex_point_verified(overrides: Option<&str>, window: u64) -> bool {
    let Some(Ok(Value::Object(o))) = overrides.map(serde_json::from_str::<Value>) else {
        return false;
    };
    let Some(Value::Object(s)) = o.get("settings") else {
        return false;
    };
    let limit = match s.get("model_auto_compact_token_limit") {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => return false,
    };
    o.get("harness").and_then(Value::as_str) == Some("codex")
        && word(s, "model_auto_compact_token_limit_scope") == "body_after_prefix"
        && word(s, "model_post_turn_compact_threshold_percent") == "0"
        && !limit.is_empty()
        && limit.bytes().all(|b| b.is_ascii_digit())
        && limit.parse::<u128>().is_ok_and(|l| l >= u128::from(window))
}

/// Pi's usage fields: input, output and both cache counts, the sum Pi's
/// own `totalTokens` is.
const PI_FIELDS: [&str; 4] = ["input", "output", "cacheRead", "cacheWrite"];

/// One reading of a Pi session file: the last message carrying a usage
/// object, its model spelled `provider/id` where the message names its
/// provider, the way the account a Pi session spends is named. Pi keeps no
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
        let Some(Value::Object(message)) = line.get("message") else {
            continue;
        };
        let Some(Value::Object(usage)) = message.get("usage") else {
            continue;
        };
        last = if PI_FIELDS.iter().any(|f| usage.contains_key(*f)) {
            let (provider, id) = (word(message, "provider"), word(message, "model"));
            let model = if provider.is_empty() || id.is_empty() {
                id.to_owned()
            } else {
                format!("{provider}/{id}")
            };
            Usage::Measured {
                tokens: summed(usage, &PI_FIELDS)?,
                window: None,
                model,
            }
        } else {
            Usage::Unread
        };
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

/// A Pi settings file that is there and cannot be read: the file, and why.
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
    let whole = |value: Option<&Value>| {
        let number = value?.as_number()?;
        if let Some(n) = number.as_u64() {
            return Some(n);
        }
        let f = number.as_f64()?;
        // A float with no fraction from 0 below `u64::MAX` converts exactly.
        (f >= 0.0 && f.fract() == 0.0 && f < u64::MAX as f64).then_some(f as u64)
    };
    let tokens = whole(current_tokens).ok_or("current_tokens is no whole number")?;
    let limit = whole(token_limit)
        .filter(|limit| *limit > 0)
        .ok_or("token_limit is no whole number above 0")?;
    Ok((tokens, limit.saturating_mul(COPILOT_COMPACTION_PCT) / 100))
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
/// its account directory, the transcript where `transcript` names one, and
/// a stamp no more than [`COPILOT_RECORD_MAX_AGE`] seconds before `now` and
/// none after it. `Err` names the first binding that did not agree:
/// `unbound` (a session id outside the alphabet that keeps the path under
/// its directory), `missing`, `unreadable` (no record of this form),
/// `wrong-session`, `wrong-account`, `wrong-transcript`, `stale`.
pub fn copilot_record(
    home: &Path,
    session: &str,
    transcript: &str,
    now: u64,
) -> Result<CopilotRecord, &'static str> {
    let bound = !matches!(session, "" | "." | "..")
        && session
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
    if !bound {
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
    if !transcript.is_empty() && word(&record, "transcript_path") != transcript {
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

    const CODEX_OFF: &str = r#"{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0"}}"#;

    #[test]
    fn a_claude_transcript_reads_its_last_usage_line_and_names_a_window_only_with_compaction_off() {
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
            (&two, false, measured(300_000, None, "claude-opus-5-5")),
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
    fn a_codex_rollout_names_its_window_only_under_overrides_that_keep_compaction_past_it() {
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
        let rows: [(&str, Option<&str>, Usage); 5] = [
            (
                &last,
                Some(CODEX_OFF),
                measured(232_560, Some(258_400), "gpt-6-astra"),
            ),
            (
                &null_info,
                Some(CODEX_OFF),
                measured(1000, Some(258_400), "gpt-6-astra"),
            ),
            (&unread, Some(CODEX_OFF), Usage::Unread),
            (
                &codex_context("gpt-6-astra"),
                Some(CODEX_OFF),
                Usage::Absent,
            ),
            (&last, None, measured(232_560, None, "gpt-6-astra")),
        ];
        for (text, overrides, want) in rows {
            assert_eq!(codex(text, overrides), Ok(want), "{text}");
        }
        let unresolved = [
            "not-json",
            "[]",
            r#"{"harness":"codex","settings":false}"#,
            r#"{"harness":"claude","settings":{}}"#,
            r#"{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807"}}"#,
            r#"{"harness":"codex","settings":{"model_auto_compact_token_limit":"200000","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0"}}"#,
            r#"{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807","model_auto_compact_token_limit_scope":"total","model_post_turn_compact_threshold_percent":"0"}}"#,
            r#"{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"80"}}"#,
        ];
        for overrides in unresolved {
            assert_eq!(
                codex(&last, Some(overrides)),
                Ok(measured(232_560, None, "gpt-6-astra")),
                "{overrides}"
            );
        }
        let at_window = r#"{"harness":"codex","settings":{"model_auto_compact_token_limit":"258400","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0"}}"#;
        assert_eq!(
            codex(&last, Some(at_window)),
            Ok(measured(232_560, Some(258_400), "gpt-6-astra"))
        );
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
            Ok(measured(1000, None, "claude-opus-5-5"))
        );
        text.push('\n');
        text.push_str(&claude_line("claude-opus-5-5", 5000));
        std::fs::write(&path, &text).unwrap();
        assert_eq!(
            read_file(&path, |t| claude(t, false)),
            Ok(measured(5000, None, "claude-opus-5-5"))
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
        serde_json::json!({"session_id": "s1", "transcript_path": "/t/s1/events.jsonl",
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
