//! The context record a session's turn-end hook writes, `context.json` in
//! the session's mailbox: the overseer's, read three-valued as its own,
//! another session's, absent, or unreadable with its cause (a record
//! another session wrote, a predecessor's until this one's first reading,
//! says nothing of this one: one naming another pane, a harness other than
//! the fleet record's for the pane, or a session other than the pane's
//! latest `SessionStart` row names); and a lane's, read from its own
//! mailbox by the same rule for the report duty, through its host where
//! its record names one.
//!
//! The judgements, each over a record the session owns: `--context
//! TOKENS:WINDOW` handed to the account judge, so the watch judges the
//! context mark between turn ends as the hook judges it at one; `stale`,
//! a record more than [`STALE_SECS`] old with a Stop row after it (the
//! hook ran and the record did not follow); `unmeasured`, a record carrying
//! a gap instead of a reading, said to the overseer once and to the owner
//! on the next pass; and `wedged`, a reading that fills the window with no
//! Stop row after it, which the observation duty reads as the session gone
//! (`source=context`). A reading the judge cannot take is noted on stderr
//! and settles nothing.

use std::io::Write;
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use agent_runtime::harness::Harness;
use agent_runtime::reading::Reading;
use serde_json::Value;

use super::hosted::{self, Answer, Files};
use crate::marker::CONTEXT_RECORD;
use crate::state::Lane;

/// A record older than this with a later Stop row is stale
/// (`OVERSEER_CONTEXT_STALE_SECS`).
pub const STALE_SECS: u64 = 3600;

/// The baseline row kind one standing gap's turn is kept under, keyed by
/// the pane key: `<gap>|told` then `<gap>|alerted`.
pub const GAP_ROW: &str = "overseer-context-gap";

/// The record's fields as `lane_context_record` writes them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextRecord {
    pub harness: Option<String>,
    /// The tokens the last response left in the context; `None` with a gap.
    pub tokens: Option<u64>,
    /// The window the adapter named, where it named one.
    pub window: Option<u64>,
    pub model: Option<String>,
    /// Where the window came from, where it is not the window the harness
    /// itself reported as its capacity.
    pub capacity_source: Option<String>,
    pub session_id: Option<String>,
    pub pane_key: Option<String>,
    /// Why a turn end took no reading, where it took none.
    pub gap: Option<String>,
    pub at: Option<String>,
}

impl ContextRecord {
    /// The record as `lane_context_record_fields` admits it: an object
    /// whose `tokens` is a number with no gap, or whose `tokens` is null
    /// with a non-empty `gap`. Anything else is a record this reader
    /// cannot judge.
    pub fn parse(text: &str) -> Result<ContextRecord, String> {
        let value: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
        let Value::Object(fields) = &value else {
            return Err("not an object".to_owned());
        };
        let tokens = match fields.get("tokens") {
            Some(Value::Number(n)) => n.as_u64().map(Some).ok_or("tokens not a whole number")?,
            None | Some(Value::Null) => None,
            Some(_) => return Err("tokens not a number".to_owned()),
        };
        let gap = match fields.get("gap") {
            Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
            None | Some(Value::Null) => None,
            Some(_) => return Err("gap not a word".to_owned()),
        };
        if tokens.is_some() == gap.is_some() {
            return Err("a reading carries tokens or a gap, never both or neither".to_owned());
        }
        let text = |key: &str| fields.get(key).and_then(Value::as_str).map(str::to_owned);
        let window = match fields.get("window") {
            Some(Value::Number(n)) => n.as_u64(),
            None | Some(_) => None,
        };
        Ok(ContextRecord {
            harness: text("harness"),
            tokens,
            window,
            model: text("model"),
            capacity_source: text("capacity_source"),
            session_id: text("session_id"),
            pane_key: text("pane_key"),
            gap,
            at: text("at"),
        })
    }

    /// The one writer of a session's record: `context.json` in `mailbox`,
    /// through a file renamed over it so no reader meets half a record,
    /// with the whole percent of the window used beside the reading.
    #[allow(
        clippy::disallowed_methods,
        reason = "the session's context record is a mailbox file no state store holds; this is its one writer, through the record module's atomic replace"
    )]
    pub fn write_to(&self, mailbox: &Path) -> Result<(), String> {
        let used_pct = match (self.tokens, self.window) {
            (Some(tokens), Some(window)) if window > 0 => Some(tokens.saturating_mul(100) / window),
            _ => None,
        };
        let value = serde_json::json!({
            "harness": self.harness,
            "model": self.model,
            "tokens": self.tokens,
            "window": self.window,
            "used_pct": used_pct,
            "capacity_source": self.capacity_source,
            "session_id": self.session_id,
            "pane_key": self.pane_key,
            "gap": self.gap,
            "at": self.at,
        });
        agent_runtime::record::replace_atomically(&mailbox.join(CONTEXT_RECORD), &value)
            .map_err(|e| e.to_string())
    }

    /// The `TOKENS:WINDOW` word the marks judge (`overseer::judge_marks`)
    /// takes: the tokens with the window where one is named; `None` for a
    /// gap.
    pub fn context_arg(&self) -> Option<String> {
        let tokens = self.tokens?;
        Some(format!(
            "{tokens}:{}",
            self.window.map(|w| w.to_string()).unwrap_or_default()
        ))
    }

    /// Whether a reading of a `harness` session
    /// fills the window it names, so the session can take no turn again.
    /// Only the window a claude, codex or pi reading names is the hard
    /// limit a session stops at; a copilot reading's window is its
    /// compaction point, never full. A reading with no window of its own
    /// takes the harness's declared capacity for its model
    /// (`Harness::context_capacity`), and one with neither is never full.
    /// `None` for a harness no adapter reads.
    pub fn window_full(&self, harness: Harness) -> Option<bool> {
        match harness {
            Harness::Copilot => return Some(false),
            Harness::Claude | Harness::Codex | Harness::Pi => {}
        }
        let tokens = self.tokens?;
        let window = self
            .window
            .filter(|w| *w > 0)
            .or_else(|| harness.context_capacity(self.model.as_deref()?));
        Some(window.is_some_and(|w| tokens >= w))
    }
}

/// What a read of the overseer's record settled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Owned {
    /// This session's own record.
    Own(ContextRecord),
    /// A record another session wrote: another pane, harness or session.
    Other,
    /// No record.
    Absent,
    /// The record, or the rows it is judged beside, could not be read.
    Unreadable { path: PathBuf, cause: String },
}

/// The last row of `file` whose `event` is `event`, over the whole file
/// as `session_rows_last FILE EVENT` finds it: `Gone` where the file is
/// absent or holds none, `Unreadable` where it could not be read. A line
/// that is no object is a fragment a killed writer left and is passed
/// over, as the library passes it.
pub fn last_event(file: &Path, event: &str) -> Reading<Value> {
    let text = match std::fs::read_to_string(file) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Reading::Gone,
        Err(_) => {
            return Reading::Unreadable {
                cause: "rows-file-unreadable",
            };
        }
    };
    last_event_in(&text, event).map_or(Reading::Gone, Reading::Live)
}

fn last_event_in(text: &str, event: &str) -> Option<Value> {
    text.lines()
        .rev()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(|row| row.is_object() && row.get("event").and_then(Value::as_str) == Some(event))
}

/// The record at `record` where it is the session
/// in `pane_key`'s own, judged beside its rows file `rows` (the pane's
/// session rows, where the fleet record names one). `harness` is the
/// fleet record's for the pane, where recorded.
pub fn own(record: &Path, rows: Option<&Path>, pane_key: &str, harness: Option<Harness>) -> Owned {
    let text = match std::fs::read_to_string(record) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Owned::Absent,
        Err(e) => {
            return Owned::Unreadable {
                path: record.to_path_buf(),
                cause: e.to_string(),
            };
        }
    };
    let parsed = match ContextRecord::parse(&text) {
        Ok(parsed) => parsed,
        Err(cause) => {
            return Owned::Unreadable {
                path: record.to_path_buf(),
                cause,
            };
        }
    };
    if parsed.pane_key.as_deref() != Some(pane_key) {
        return Owned::Other;
    }
    if let Some(h) = harness
        && parsed.harness.as_deref() != Some(h.name())
    {
        return Owned::Other;
    }
    let started = match rows.map(|r| last_event(r, "SessionStart")) {
        None | Some(Reading::Gone) => String::new(),
        Some(Reading::Live(row)) => row
            .get("session_id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        Some(Reading::Unreadable { cause }) => {
            return Owned::Unreadable {
                path: rows.map(Path::to_path_buf).unwrap_or_default(),
                cause: cause.to_owned(),
            };
        }
    };
    match &parsed.session_id {
        Some(session) if !started.is_empty() && !session.is_empty() && *session != started => {
            Owned::Other
        }
        Some(_) | None => Owned::Own(parsed),
    }
}

/// The two instants the stale and the wedged judgements compare: the
/// record's own `at` and the epoch of the last Stop row, 0 for none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Times {
    Read { at: u64, stop: u64 },
    Unread { path: PathBuf, cause: String },
}

pub fn times(record: &ContextRecord, record_path: &Path, rows: Option<&Path>) -> Times {
    let Some(at) = record.at.as_deref().and_then(clock::epoch_secs) else {
        return Times::Unread {
            path: record_path.to_path_buf(),
            cause: format!("at={}", record.at.as_deref().unwrap_or("none")),
        };
    };
    let stop = match rows.map(|r| last_event(r, "Stop")) {
        None | Some(Reading::Gone) => 0,
        Some(Reading::Live(row)) => stop_epoch(&row),
        Some(Reading::Unreadable { cause }) => {
            return Times::Unread {
                path: rows.map(Path::to_path_buf).unwrap_or_default(),
                cause: cause.to_owned(),
            };
        }
    };
    Times::Read { at, stop }
}

fn stop_epoch(row: &Value) -> u64 {
    match row.get("at") {
        Some(Value::Number(n)) => n.as_u64().unwrap_or(0),
        Some(Value::String(s)) => s
            .parse()
            .or_else(|_| clock::epoch_secs(s).ok_or(()))
            .unwrap_or(0),
        None | Some(_) => 0,
    }
}

/// A reading the judge cannot take, noted on stderr for the launcher's
/// record of this run; it settles nothing.
pub fn note(key: &str, fields: &str) {
    let _ = writeln!(std::io::stderr(), "{key} {fields}");
}

/// The owner's alert for a gap that stood two long passes.
pub fn alert_text(pane: &str, gap: &str) -> String {
    format!(
        "overseer-context-unmeasured: the overseer in pane {pane} has recorded no context reading on two consecutive watch passes, gap={gap}, so nothing judges its context mark and it can run into its context window with no handoff. The remedy for this gap is under overseer-context-unmeasured in the orch skill's references/overseer-session-events.md.\n"
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Standing {
    Current,
    /// The record is more than [`STALE_SECS`] old and the lane's rows hold
    /// a Stop row after it: the hook ran and the record did not follow.
    Stale,
}

/// What a read of a lane's context record settled, for the report duty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaneContext {
    /// No record, or an empty one: no turn end of this lane has recorded
    /// a reading since its launch.
    Unrecorded,
    /// A record another session wrote: another harness, or another session
    /// than the lane record binds.
    Other,
    /// The record, or the rows it is judged beside, could not be read.
    Unreadable { cause: String },
    Own {
        record: ContextRecord,
        standing: Standing,
    },
}

/// A lane's record, read as the overseer's is (`own`): from the mailbox
/// its fleet record places, `tmp/lane-mail/<item>` under its mail root,
/// by the host's `files` capability (locally, through the provider's
/// `cat`, or not at all), and judged beside its rows file for the Stop
/// row the stale rule compares against.
pub fn lane(lane: &Lane, files: Files, scripts: &Path, now: u64) -> LaneContext {
    let Some(root) = lane.mail_root.as_deref().filter(|r| !r.is_empty()) else {
        return LaneContext::Unreadable {
            cause: "mail-root-unnamed".to_owned(),
        };
    };
    let mailbox = Path::new(root)
        .join("tmp")
        .join("lane-mail")
        .join(&lane.item);
    let read = |name: &str| -> Result<Option<String>, String> {
        let path = mailbox.join(name);
        match files {
            Files::Local => match std::fs::read_to_string(&path) {
                Ok(text) => Ok(Some(text)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(e) => Err(format!("{}: {e}", path.display())),
            },
            Files::Verb => match hosted::fetch(
                scripts,
                hosted::host_of(lane),
                &lane.item,
                &path.display().to_string(),
            ) {
                Answer::Live(text) => Ok(Some(text)),
                Answer::Gone => Ok(None),
                Answer::Unreadable { cause } => Err(cause),
            },
            Files::None => Err("files-none".to_owned()),
        }
    };
    let text = match read("context.json") {
        Ok(Some(text)) if !text.trim().is_empty() => text,
        Ok(_) => return LaneContext::Unrecorded,
        Err(cause) => return LaneContext::Unreadable { cause },
    };
    let record = match ContextRecord::parse(&text) {
        Ok(record) => record,
        Err(cause) => return LaneContext::Unreadable { cause },
    };
    if let Some(h) = lane.harness.as_deref().and_then(Harness::parse)
        && record.harness.as_deref() != Some(h.name())
    {
        return LaneContext::Other;
    }
    if let (Some(bound), Some(session)) = (lane.session_id.as_deref(), record.session_id.as_deref())
        && !bound.is_empty()
        && !session.is_empty()
        && bound != session
    {
        return LaneContext::Other;
    }
    let Some(at) = record.at.as_deref().and_then(clock::epoch_secs) else {
        return LaneContext::Unreadable {
            cause: format!("at={}", record.at.as_deref().unwrap_or("none")),
        };
    };
    let stop = match read("session-rows.jsonl") {
        Ok(Some(rows)) => last_event_in(&rows, "Stop").map_or(0, |row| stop_epoch(&row)),
        Ok(None) => 0,
        Err(cause) => return LaneContext::Unreadable { cause },
    };
    let standing = if now.saturating_sub(at) > STALE_SECS && stop > at {
        Standing::Stale
    } else {
        Standing::Current
    };
    LaneContext::Own { record, standing }
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the rows plant the record and the rows file they read"
)]
mod tests {
    use super::*;

    /// The record's two shapes, and what is neither (`lane_context_record
    /// _fields`): a reading with tokens and no gap, a gap with no tokens.
    #[test]
    fn a_record_is_a_reading_or_a_gap_and_nothing_else() {
        let reading = ContextRecord::parse(
            r#"{"harness":"claude","model":"opus","tokens":910000,"window":1000000,"session_id":"s1","pane_key":"4242 %7","gap":null,"at":"2026-10-01T00:00:00Z"}"#,
        )
        .unwrap();
        assert_eq!(reading.tokens, Some(910_000));
        assert_eq!(reading.context_arg().as_deref(), Some("910000:1000000"));
        assert_eq!(reading.window_full(Harness::Claude), Some(false));
        let gap = ContextRecord::parse(
            r#"{"harness":"claude","tokens":null,"window":null,"pane_key":"4242 %7","gap":"pane-unrecorded","at":"2026-10-01T00:00:00Z"}"#,
        )
        .unwrap();
        assert_eq!(gap.gap.as_deref(), Some("pane-unrecorded"));
        assert_eq!(gap.context_arg(), None);
        for bad in [
            r#"{"tokens":1,"gap":"x"}"#,
            r#"{"tokens":null,"gap":null}"#,
            r#"{"tokens":"1"}"#,
            "[]",
            "not json",
        ] {
            assert!(ContextRecord::parse(bad).is_err(), "{bad}");
        }
    }

    /// The full-window table: the window a claude, codex or pi
    /// reading names is the hard limit; a copilot reading is never full; a
    /// reading naming no window takes the declared capacity for its model,
    /// and one naming neither is never full.
    #[test]
    fn a_window_is_full_at_its_own_figure_or_the_declared_capacity() {
        let record = |tokens: u64, window: Option<u64>, model: Option<&str>| ContextRecord {
            harness: None,
            tokens: Some(tokens),
            window,
            model: model.map(str::to_owned),
            capacity_source: None,
            session_id: None,
            pane_key: None,
            gap: None,
            at: None,
        };
        assert_eq!(
            record(1_000_000, Some(1_000_000), None).window_full(Harness::Claude),
            Some(true)
        );
        assert_eq!(
            record(999_999, Some(1_000_000), None).window_full(Harness::Codex),
            Some(false)
        );
        assert_eq!(
            record(1_000_000, Some(1_000_000), None).window_full(Harness::Copilot),
            Some(false)
        );
        assert_eq!(
            record(200_000, None, Some("claude-haiku-5-5")).window_full(Harness::Claude),
            Some(true)
        );
        assert_eq!(
            record(200_000, None, Some("claude-fable-5-1")).window_full(Harness::Claude),
            Some(false)
        );
        assert_eq!(
            record(200_000, None, None).window_full(Harness::Pi),
            Some(false)
        );
        assert_eq!(
            record(5, Some(0), None).window_full(Harness::Pi),
            Some(false)
        );
    }

    #[test]
    fn a_lanes_record_with_a_stale_turn_end_reads_stale_not_current() {
        let dir = tempfile::tempdir().unwrap();
        let mailbox = dir.path().join("tmp").join("lane-mail").join("KEN-1");
        std::fs::create_dir_all(&mailbox).unwrap();
        let lane: Lane = serde_json::from_value(serde_json::json!({
            "item": "KEN-1", "status": "running", "harness": "pi", "session_id": "s1",
            "mail_root": dir.path().display().to_string(),
            "launch": {"server": 4242, "pane": "%7"}
        }))
        .unwrap();
        let at = 1_799_971_200;
        // The record as the lane's own turn end writes it: no pane key, the
        // session the hook ran in.
        let record = |session: &str| {
            std::fs::write(
                mailbox.join("context.json"),
                format!(
                    r#"{{"harness":"pi","model":"m","tokens":1000,"window":200000,"session_id":"{session}","pane_key":null,"gap":null,"at":"{}"}}"#,
                    clock::iso_utc(at)
                ),
            )
            .unwrap();
        };
        let stop_row = |stop: u64| {
            std::fs::write(
                mailbox.join("session-rows.jsonl"),
                format!("{{\"at\":{stop},\"event\":\"Stop\",\"harness\":\"pi\"}}\n"),
            )
            .unwrap();
        };
        let read = |now: u64| super::lane(&lane, Files::Local, dir.path(), now);
        assert_eq!(read(at + 2 * STALE_SECS), LaneContext::Unrecorded);
        record("s1");
        let own = |standing: Standing| match read(at + 2 * STALE_SECS) {
            LaneContext::Own {
                record,
                standing: read,
            } => {
                assert_eq!(record.tokens, Some(1000));
                assert_eq!(read, standing);
            }
            other => panic!("{other:?}"),
        };
        own(Standing::Current);
        stop_row(at + STALE_SECS);
        own(Standing::Stale);
        stop_row(at - 100);
        own(Standing::Current);
        stop_row(at + STALE_SECS);
        assert!(matches!(
            read(at + STALE_SECS),
            LaneContext::Own {
                standing: Standing::Current,
                ..
            }
        ));
        record("s2");
        assert_eq!(read(at + 2 * STALE_SECS), LaneContext::Other);
        std::fs::write(mailbox.join("context.json"), "not json").unwrap();
        assert!(matches!(
            read(at + 2 * STALE_SECS),
            LaneContext::Unreadable { .. }
        ));
    }
}
