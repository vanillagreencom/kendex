//! What a harness session's context holds, read from the file the harness
//! itself writes for the session and never from a pane: the tokens the last
//! response left in the context, the window a reading is judged against
//! where that window is a verified point, and the model. One reader per
//! harness, for every caller; a value only the caller's own rules know (a
//! launch's compaction overrides, a window a hook payload named) comes in
//! as an argument.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::harness::Harness;

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

/// The usage `read` takes from the session file at `path`: from its last
/// [`TAIL_BYTES`] first, then from the whole file where that tail holds no
/// usage line. The tail opens on a partial line, which `read` passes over
/// as it passes over any line that is no JSON (the line the harness is
/// still appending included). `Err` where the file cannot be opened or
/// read, or where `read` refuses a line it cannot sum.
pub fn read_file(
    path: &Path,
    read: impl Fn(&str) -> Result<Usage, String>,
) -> Result<Usage, String> {
    let fail = |e: io::Error| format!("{}: {e}", path.display());
    let mut file = File::open(path).map_err(fail)?;
    let len = file.metadata().map_err(fail)?.len();
    if len > TAIL_BYTES {
        file.seek(SeekFrom::Start(len - TAIL_BYTES)).map_err(fail)?;
        let tail = read(&lossy(&mut file).map_err(fail)?)?;
        if tail != Usage::Absent {
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
    let mut model = String::new();
    let mut last: Option<Option<(u64, Option<u64>)>> = None;
    for line in objects(text) {
        let payload = line.get("payload");
        match word(&line, "type") {
            "turn_context" => {
                if let Some(Value::String(named)) = payload.and_then(|p| p.get("model")) {
                    named.clone_into(&mut model);
                }
            }
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
            model,
        },
    })
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
}
