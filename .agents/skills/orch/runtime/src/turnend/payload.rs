//! The harness payload a turn end reads, and who made the call it
//! describes: the lead, a subagent, or a caller the payload cannot name.
//! Copilot's payloads name no agent, so its lead sessions are recorded,
//! one file per session id under the user's cache, outside every source
//! tree: a custom subagent's tool-call payloads carry its own session id and
//! nothing else that names it.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use super::answer::{LEAD_DAYS, Said};

/// Who made the call the payload describes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Caller {
    Lead,
    Subagent,
    /// A Copilot call from no recorded lead session: handed no mail and
    /// acknowledging none, so a subagent cannot take the lead's directive.
    Unknown,
}

/// The fields a turn end reads from its payload. A field present with a
/// type the reader does not take refuses the whole payload, never reads as
/// absent.
pub struct Payload {
    /// The harness set `stop_hook_active`: this turn was continued because a
    /// stop hook blocked the one before it.
    pub active: bool,
    pub caller: Caller,
    pub transcript: String,
    /// The session id, empty where the payload spells it outside the
    /// alphabet a harness spells one in: a record keyed by it then falls
    /// back as for a payload carrying none.
    pub session: String,
    pub tool: String,
    pub context_window: Option<u64>,
    /// The payload has Copilot's shape (`timestamp` or `sessionId`).
    pub copilot_call: bool,
    pub trigger: String,
    /// `kendex_ack` leaves the acknowledgement to the caller that sends the
    /// context on, the Pi wake.
    pub ack_by_caller: bool,
    /// The session directory a Copilot context reading names; read on the
    /// usage arm alone.
    pub cwd: String,
    /// Claude's `PostModelSwitch` reaches the turn-end arm.
    pub model_switch: bool,
    value: Value,
}

/// The cause a payload is refused with.
pub struct Invalid(pub String);

impl Payload {
    /// The payload `bytes` hold, decoded for `usage` where that arm reads
    /// the session directory. An empty payload carries no field. Bytes past
    /// UTF-8 are read as the replacement character, as a JSON reader reads
    /// them.
    pub fn decode(bytes: &[u8], usage: bool) -> Result<Payload, Invalid> {
        let text = String::from_utf8_lossy(bytes);
        let mut values = serde_json::Deserializer::from_str(&text).into_iter::<Value>();
        let value = match values.next() {
            None => Value::Null,
            Some(Ok(value)) => value,
            Some(Err(e)) => return Err(Invalid(e.to_string())),
        };
        if let Some(next) = values.next() {
            return Err(Invalid(match next {
                Ok(_) => "the payload holds more than one JSON document".to_owned(),
                Err(e) => e.to_string(),
            }));
        }
        if !matches!(value, Value::Object(_) | Value::Null) {
            return Err(Invalid(format!(
                "the payload is a {}, not an object",
                kind(&value)
            )));
        }
        let field = |name: &str| value.get(name).filter(|v| !v.is_null());
        let text_of = |name: &str| -> Result<String, Invalid> {
            match field(name) {
                None => Ok(String::new()),
                Some(Value::String(s)) => Ok(s.clone()),
                Some(other) => Err(Invalid(format!(
                    "{name} is a {}, not a string",
                    kind(other)
                ))),
            }
        };
        let either = |first: &str, second: &str| {
            if field(first).is_some() {
                text_of(first)
            } else {
                text_of(second)
            }
        };
        let active = value.get("stop_hook_active") == Some(&Value::Bool(true));
        let subagent = value.get("hook_event_name").and_then(Value::as_str) == Some("SubagentStop")
            || !(text_of("agent_id")? + &text_of("agent_type")?).is_empty();
        let transcript = either("transcript_path", "transcriptPath")?;
        let session = either("session_id", "sessionId")?;
        let tool = either("tool_name", "toolName")?;
        let context_window = match field("context_window") {
            None => None,
            Some(window) => Some(whole(window).ok_or_else(|| {
                Invalid(format!("context_window {window} is not a whole number"))
            })?),
        };
        let copilot_call = value.get("timestamp").is_some() || value.get("sessionId").is_some();
        let trigger = text_of("trigger")?;
        let ack_by_caller = value.get("kendex_ack").and_then(Value::as_str) == Some("caller");
        let cwd = if usage {
            text_of("cwd")?
        } else {
            String::new()
        };
        let model_switch =
            value.get("hook_event_name").and_then(Value::as_str) == Some("PostModelSwitch");
        Ok(Payload {
            active,
            caller: if subagent {
                Caller::Subagent
            } else {
                Caller::Lead
            },
            transcript,
            session: session_alphabet(session),
            tool,
            context_window,
            copilot_call,
            trigger,
            ack_by_caller,
            cwd,
            model_switch,
            value,
        })
    }

    /// The command the call about to run carries, where each harness
    /// carries it: `tool_input.command`, or Copilot's `toolArgs.command`,
    /// whose `toolArgs` arrives as an object or as one JSON-encoded string.
    /// Empty where neither names a string; a `toolArgs` string that is no
    /// JSON refuses the payload.
    pub fn command(&self) -> Result<String, Invalid> {
        if let Some(command) = self
            .value
            .get("tool_input")
            .and_then(|input| input.get("command"))
            .and_then(Value::as_str)
        {
            return Ok(command.to_owned());
        }
        let args = match self.value.get("toolArgs") {
            None | Some(Value::Null) => return Ok(String::new()),
            Some(Value::String(encoded)) => serde_json::from_str::<Value>(encoded)
                .map_err(|e| Invalid(format!("toolArgs: {e}")))?,
            Some(args) => args.clone(),
        };
        Ok(args
            .get("command")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned())
    }
}

fn kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

/// A positive whole number, spelled as an integer or as a float with no
/// fraction.
fn whole(value: &Value) -> Option<u64> {
    let number = value.as_number()?;
    if let Some(n) = number.as_u64() {
        return (n > 0).then_some(n);
    }
    let f = number.as_f64()?;
    // A positive float with no fraction below `u64::MAX` converts exactly.
    (f > 0.0 && f.fract() == 0.0 && f < u64::MAX as f64).then_some(f as u64)
}

/// The id held to the alphabet a harness spells one in, so it can be
/// composed into a record and a path; any other spelling reads as none.
fn session_alphabet(session: String) -> String {
    let plain = session
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
    if plain { session } else { String::new() }
}

/// Copilot's lead records and the pending reading markers its context
/// extension leaves, both under the user's cache. An environment variable
/// names no session here: a CLI launched from another Copilot session
/// inherits that session's.
pub struct Leads {
    dir: PathBuf,
    usage: PathBuf,
}

/// A keyed line a lead record write leaves for stderr, with its cause.
pub struct Note {
    pub said: Said,
    pub cause: String,
}

impl Leads {
    /// The records under `home`, empty where `HOME` is unset.
    pub fn under(home: &str) -> Leads {
        let cache = PathBuf::from(format!("{home}/.cache/lane-mail"));
        Leads {
            dir: cache.join("copilot-leads"),
            usage: cache.join("copilot-usage"),
        }
    }

    fn file(&self, session: &str) -> Option<PathBuf> {
        (!session.is_empty()).then(|| self.dir.join(session))
    }

    /// Whether `session` is a lead this install recorded.
    pub fn recorded(&self, session: &str) -> bool {
        self.file(session)
            .is_some_and(|file| std::fs::metadata(file).is_ok_and(|meta| meta.is_file()))
    }

    /// Record `session` as a lead at `now`, and with `prune` remove every
    /// record and pending marker untouched for [`LEAD_DAYS`]. A record that
    /// cannot be written is reported, never refused: the session goes on as
    /// a caller its tool calls leave unknown. A pruned lead that still runs
    /// records itself again at its next turn end.
    pub fn record(&self, session: &str, prune: bool, now: SystemTime) -> Vec<Note> {
        let Some(file) = self.file(session) else {
            return vec![Note {
                said: Said::LeadUnnamed,
                cause: String::new(),
            }];
        };
        if let Err(cause) = touch(&self.dir, &file, now) {
            return vec![Note {
                said: Said::LeadUnrecorded(file),
                cause,
            }];
        }
        let mut notes = Vec::new();
        for dir in [&self.dir, &self.usage] {
            if !prune || !std::fs::metadata(dir).is_ok_and(|meta| meta.is_dir()) {
                continue;
            }
            let mut causes = Vec::new();
            prune_older(dir, now, &mut causes);
            if !causes.is_empty() {
                notes.push(Note {
                    said: Said::LeadsUnpruned(dir.clone()),
                    cause: causes.join("\n"),
                });
            }
        }
        notes
    }
}

/// Make `file` under `dir`, or move its modification time to `now` where it
/// stands, which is what the prune reads.
#[allow(
    clippy::disallowed_methods,
    reason = "the Copilot lead record's one writer: the user's cache, outside every source tree and every workflow record"
)]
fn touch(dir: &Path, file: &Path, now: SystemTime) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let handle = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(file)
        .map_err(|e| format!("{}: {e}", file.display()))?;
    handle
        .set_modified(now)
        .map_err(|e| format!("{}: {e}", file.display()))
}

/// Remove every plain file under `dir`, at any depth, whose modification
/// time is more than [`LEAD_DAYS`] whole days before `now`; a link is never
/// followed or removed. What could not be read or removed is left with its
/// cause in `causes`, and the walk goes on.
#[allow(
    clippy::disallowed_methods,
    reason = "the prune of the Copilot lead records and pending markers in the user's cache, which no workflow record holds"
)]
fn prune_older(dir: &Path, now: SystemTime, causes: &mut Vec<String>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) => {
            causes.push(format!("{}: {e}", dir.display()));
            return;
        }
    };
    let age = Duration::from_secs((LEAD_DAYS + 1) * 86_400);
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(e) => {
                causes.push(format!("{}: {e}", dir.display()));
                continue;
            }
        };
        let path = entry.path();
        let meta = match std::fs::symlink_metadata(&path) {
            Ok(meta) => meta,
            Err(e) => {
                causes.push(format!("{}: {e}", path.display()));
                continue;
            }
        };
        if meta.is_dir() {
            prune_older(&path, now, causes);
            continue;
        }
        if !meta.is_file() {
            continue;
        }
        let stale = meta
            .modified()
            .ok()
            .and_then(|modified| modified.checked_add(age))
            .is_some_and(|due| due <= now);
        if stale && let Err(e) = std::fs::remove_file(&path) {
            causes.push(format!("{}: {e}", path.display()));
        }
    }
}
