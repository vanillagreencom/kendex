//! The session rows a harness's hooks write, one JSON object per line, read
//! for what the harness itself said of its session: up, walled, gone. The
//! writer is orch's `lane-mail-check` hook through `lib/session-rows.sh`,
//! whose verdict tables this reader keeps (`session_rows_verdict` for an
//! overseer's rows, `session_rows_lane_verdict` for a Pi lane's); the row
//! shapes follow Claude Code's hook inputs, Pi's carrier and Copilot's
//! camelCase payloads as that library names them.
//!
//! Every read is three-valued (decision 99): `Live(row)` is the last row,
//! `Gone` a file that is absent or holds no row, `Unreadable` a file or a
//! last row that could not be read. A verdict is read from the last row
//! alone, as the library reads it, over the last `SPAN` lines.

// Every reading is matched variant by variant (decision 105).
#![deny(clippy::wildcard_enum_match_arm)]

use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::observe::{self, WallKind};
use crate::reading::Reading;

/// The rows a reader looks back over for the last one: a session appends a
/// start, an end, a failure per wall and a Stop per turn
/// (`SESSION_ROWS_SPAN`).
pub const SPAN: usize = 64;

/// The harness's own text for a request refused for its prompt's length
/// (`SESSION_ROWS_PROMPT_TOO_LONG`), matched lowercased as a substring over
/// the row's `message` and `error_details`.
const PROMPT_TOO_LONG: [&str; 1] = ["prompt is too long"];

/// A Pi lane's ordinary turn end, which an idle verdict carries no cause
/// for: Pi's own `stop`, which both providers write for a finished turn
/// (`pi-claude-bridge/src/assistant-stream.ts` `mapStopReason`,
/// `pi-codex-minimal-tools/src/providers/openai-responses-shared.ts`
/// `mapStopReason`), and Anthropic's raw `end_turn` the bridge maps to it.
/// Every other word is carried as the harness wrote it.
const ORDINARY_END: [&str; 2] = ["stop", "end_turn"];

/// One session row as this reader takes it: the fields the two verdicts
/// read, each absent where the row carries none.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Row {
    #[serde(default)]
    pub harness: Option<String>,
    #[serde(default)]
    pub event: Option<String>,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub error_details: Option<String>,
    #[serde(default)]
    pub stop_reason: Option<String>,
    /// The carrier's count of working agents on a Pi Stop row; `null` is
    /// the carrier's failed task read, kept apart from an absent key as
    /// the library's `has("working_agents")` keeps it.
    #[serde(default, deserialize_with = "present")]
    pub working_agents: Option<Value>,
    #[serde(default)]
    pub session_id: Option<String>,
    /// The epoch second the row was written at.
    #[serde(default)]
    pub at: Option<u64>,
}

/// A key that is present, whatever its value: `Some(Null)` for a written
/// `null`, where serde's own `Option` reads `None`.
fn present<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Option<Value>, D::Error> {
    Value::deserialize(d).map(Some)
}

/// What an overseer's last row says of its session (`session_rows_verdict`).
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "verdict", rename_all = "kebab-case")]
pub enum SessionVerdict {
    /// The row carries no evidence this verdict reads: a harness other than
    /// Claude Code or Pi, or a Pi row that is neither a SessionEnd nor a
    /// StopFailure with a `message`.
    Unsupported,
    /// A SessionEnd for any reason but `clear` and `resume`.
    Ended,
    /// A StopFailure the account refused: the error kinds that refuse every
    /// turn until a person acts (`auth`), or a usage limit (`usage`).
    Walled { kind: WallKind },
    /// A StopFailure for a prompt too long: every turn fails the same way
    /// while the harness stays up.
    Wedged,
    /// Any other Claude Code row, a SessionEnd for `clear` or `resume`, or a
    /// Pi StopFailure whose message names neither a limit nor a prompt too
    /// long.
    Live,
}

/// What a Pi lane's last row says (`session_rows_lane_verdict`).
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "verdict", rename_all = "kebab-case")]
pub enum LaneVerdict {
    /// A PreToolUse row, or a Stop whose carrier counts working agents.
    Working,
    /// A Stop row that ended no error, or an error that is no limit;
    /// `cause` is the row's `stop_reason` word where the harness wrote
    /// one that is not its ordinary end ([`ORDINARY_END`]; Pi's `length`
    /// is a turn its output limit cut), so the stop's cause reaches the
    /// line the overseer reads and a finished round carries none.
    Idle { cause: Option<String> },
    /// A Stop row whose error message is the account's limit.
    Walled,
}

/// The last row of `file`, from the last [`SPAN`] lines: `Gone` where the
/// file is absent or holds no row, `Unreadable` where it, or the row, could
/// not be read.
pub fn last_row(file: &Path) -> Reading<Row> {
    let f = match fs::File::open(file) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Reading::Gone,
        Err(_) => {
            return Reading::Unreadable {
                cause: "rows-file-unreadable",
            };
        }
    };
    let mut lines: Vec<String> = Vec::new();
    for line in BufReader::new(f).lines() {
        match line {
            Ok(line) => lines.push(line),
            Err(_) => {
                return Reading::Unreadable {
                    cause: "rows-file-unreadable",
                };
            }
        }
    }
    let start = lines.len().saturating_sub(SPAN);
    let Some(last) = lines[start..].iter().rev().find(|l| !l.trim().is_empty()) else {
        return Reading::Gone;
    };
    match serde_json::from_str::<Value>(last) {
        Ok(Value::Object(_)) => match serde_json::from_str::<Row>(last) {
            Ok(row) => Reading::Live(row),
            Err(_) => Reading::Unreadable {
                cause: "rows-row-unparsed",
            },
        },
        // A fragment a killed writer left, or a line that is no object,
        // is a row this reader cannot judge, never an absent one.
        Ok(
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) | Value::Array(_),
        )
        | Err(_) => Reading::Unreadable {
            cause: "rows-row-unparsed",
        },
    }
}

/// The overseer verdict of `file`'s last row.
pub fn session_verdict(file: &Path) -> Reading<SessionVerdict> {
    last_row(file).map(|row| judge_session(&row))
}

/// The verdict table of `session_rows_verdict`, over one row.
pub fn judge_session(row: &Row) -> SessionVerdict {
    let harness = row.harness.as_deref().unwrap_or("");
    let event = row.event.as_deref().unwrap_or("");
    let message = row.message.as_deref().unwrap_or("");
    if harness == "claude"
        && event == "StopFailure"
        && observe::is_auth_failure("", row.error.as_deref())
    {
        return SessionVerdict::Walled {
            kind: WallKind::Auth,
        };
    }
    if harness != "claude" && harness != "pi" {
        return SessionVerdict::Unsupported;
    }
    if event == "SessionEnd" {
        return match row.reason.as_deref() {
            Some("clear" | "resume") => SessionVerdict::Live,
            Some(_) | None => SessionVerdict::Ended,
        };
    }
    if event == "StopFailure" && harness == "claude" && row.error.as_deref() == Some("rate_limit") {
        return SessionVerdict::Walled {
            kind: WallKind::Usage,
        };
    }
    if harness == "pi" && (event != "StopFailure" || message.is_empty()) {
        return SessionVerdict::Unsupported;
    }
    if event == "StopFailure" {
        let text =
            format!("{message}\n{}", row.error_details.as_deref().unwrap_or("")).to_lowercase();
        if PROMPT_TOO_LONG.iter().any(|p| text.contains(p)) {
            return SessionVerdict::Wedged;
        }
    }
    if harness == "pi" {
        return match observe::limit_banner(message) {
            Some(_) => SessionVerdict::Walled {
                kind: WallKind::Usage,
            },
            None => SessionVerdict::Live,
        };
    }
    SessionVerdict::Live
}

/// The Pi lane verdict of `file`'s last row: a row the table cannot judge
/// is `Unreadable`, as the library exits 2 on it.
pub fn lane_verdict(file: &Path) -> Reading<LaneVerdict> {
    match last_row(file) {
        Reading::Live(row) => judge_lane(&row),
        Reading::Gone => Reading::Gone,
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
    }
}

/// The verdict table of `session_rows_lane_verdict`, over one row.
pub fn judge_lane(row: &Row) -> Reading<LaneVerdict> {
    let event = row.event.as_deref().unwrap_or("");
    if event == "Stop"
        && let Some(count) = &row.working_agents
    {
        // Null is the carrier's failed task read, never evidence of an
        // idle lane; so is a count that is no whole number.
        let Some(n) = count.as_u64() else {
            return Reading::Unreadable {
                cause: "working-agents-unread",
            };
        };
        if n > 0 {
            return Reading::Live(LaneVerdict::Working);
        }
    }
    let idle = || {
        Reading::Live(LaneVerdict::Idle {
            cause: row
                .stop_reason
                .as_deref()
                .filter(|word| !ORDINARY_END.contains(word))
                .map(str::to_owned),
        })
    };
    match (event, row.stop_reason.as_deref()) {
        ("PreToolUse", _) => Reading::Live(LaneVerdict::Working),
        ("Stop", Some("error")) => {
            match observe::limit_banner(row.message.as_deref().unwrap_or("")) {
                Some(_) => Reading::Live(LaneVerdict::Walled),
                None => idle(),
            }
        }
        ("Stop", Some(_) | None) => idle(),
        (_, _) => Reading::Unreadable {
            cause: "lane-row-unjudged",
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(json: &str) -> Row {
        serde_json::from_str(json).unwrap()
    }

    /// The overseer verdict table, one row per form the library judges:
    /// each harness's SessionEnd and StopFailure shapes, a Pi row with and
    /// without a limit message, a Copilot row, and the too-long prompt.
    /// Defect: a verdict that drifts from the library's, which reads the
    /// same file for the same decision until the legacy watch retires.
    #[test]
    fn the_session_verdict_follows_the_library_s_table_per_harness_form() {
        let rows: [(&str, SessionVerdict); 11] = [
            (
                r#"{"harness":"claude","event":"SessionEnd","reason":"exit"}"#,
                SessionVerdict::Ended,
            ),
            (
                r#"{"harness":"claude","event":"SessionEnd","reason":"clear"}"#,
                SessionVerdict::Live,
            ),
            (
                r#"{"harness":"pi","event":"SessionEnd","reason":"resume"}"#,
                SessionVerdict::Live,
            ),
            (
                r#"{"harness":"claude","event":"StopFailure","error":"rate_limit","message":"You've hit your weekly limit"}"#,
                SessionVerdict::Walled {
                    kind: WallKind::Usage,
                },
            ),
            (
                r#"{"harness":"claude","event":"StopFailure","error":"authentication_failed"}"#,
                SessionVerdict::Walled {
                    kind: WallKind::Auth,
                },
            ),
            (
                r#"{"harness":"claude","event":"StopFailure","error":"other","message":"Prompt is too long"}"#,
                SessionVerdict::Wedged,
            ),
            (
                r#"{"harness":"claude","event":"Stop","session_id":"s"}"#,
                SessionVerdict::Live,
            ),
            (
                r#"{"harness":"pi","event":"StopFailure","message":"429 Usage limit reached for this model"}"#,
                SessionVerdict::Walled {
                    kind: WallKind::Usage,
                },
            ),
            (
                r#"{"harness":"pi","event":"StopFailure","message":"connection reset"}"#,
                SessionVerdict::Live,
            ),
            (
                r#"{"harness":"pi","event":"Stop"}"#,
                SessionVerdict::Unsupported,
            ),
            (
                r#"{"harness":"copilot","event":"SessionEnd","reason":"exit"}"#,
                SessionVerdict::Unsupported,
            ),
        ];
        for (json, expected) in rows {
            assert_eq!(judge_session(&row(json)), expected, "{json}");
        }
    }

    /// The Pi lane verdict table. Defect: a carrier's null count read as
    /// an idle lane, or a row the table cannot judge read as one; an idle
    /// verdict that drops the row's `stop_reason`, so a turn the output
    /// limit cut (`length`) reads as a finished one, or that carries the
    /// harness's ordinary end (`stop`, `end_turn`), so every finished
    /// round reads as a cause.
    #[test]
    fn the_lane_verdict_reads_working_idle_and_walled_and_refuses_what_it_cannot_judge() {
        let idle = |cause: Option<&str>| {
            Reading::Live(LaneVerdict::Idle {
                cause: cause.map(str::to_owned),
            })
        };
        let rows: [(&str, Reading<LaneVerdict>); 11] = [
            (
                r#"{"harness":"pi","event":"PreToolUse"}"#,
                Reading::Live(LaneVerdict::Working),
            ),
            (
                r#"{"harness":"pi","event":"Stop","working_agents":2}"#,
                Reading::Live(LaneVerdict::Working),
            ),
            (
                r#"{"harness":"pi","event":"Stop","working_agents":0}"#,
                idle(None),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"stop","working_agents":0}"#,
                idle(None),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"end_turn"}"#,
                idle(None),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"length","working_agents":0}"#,
                idle(Some("length")),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"toolUse","working_agents":0}"#,
                idle(Some("toolUse")),
            ),
            (
                r#"{"harness":"pi","event":"Stop","working_agents":null}"#,
                Reading::Unreadable {
                    cause: "working-agents-unread",
                },
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"error","message":"429 Usage limit reached for this model"}"#,
                Reading::Live(LaneVerdict::Walled),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"error","message":"tool failed"}"#,
                idle(Some("error")),
            ),
            (
                r#"{"harness":"pi","event":"SessionStart"}"#,
                Reading::Unreadable {
                    cause: "lane-row-unjudged",
                },
            ),
        ];
        for (json, expected) in rows {
            assert_eq!(judge_lane(&row(json)), expected, "{json}");
        }
    }

    /// The file read is three-valued and reads the last row alone: an
    /// absent file and an empty one are `Gone`, the last object within the
    /// span decides over every earlier row, and a trailing fragment a killed
    /// writer left is unreadable, never the row before it and never absent.
    #[test]
    fn the_last_row_is_read_three_valued_over_the_span() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("session-7-9.jsonl");
        assert_eq!(last_row(&file), Reading::Gone);
        fs::write(&file, "\n\n").unwrap();
        assert_eq!(last_row(&file), Reading::Gone);
        let mut text = String::new();
        for _ in 0..(SPAN + 5) {
            text.push_str(r#"{"harness":"claude","event":"StopFailure","error":"rate_limit"}"#);
            text.push('\n');
        }
        text.push_str(r#"{"harness":"claude","event":"SessionEnd","reason":"exit"}"#);
        text.push('\n');
        fs::write(&file, &text).unwrap();
        assert_eq!(session_verdict(&file), Reading::Live(SessionVerdict::Ended));
        text.push_str(r#"{"harness":"claude","event":"Sto"#);
        fs::write(&file, &text).unwrap();
        assert_eq!(
            last_row(&file),
            Reading::Unreadable {
                cause: "rows-row-unparsed"
            }
        );
    }
}
