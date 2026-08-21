use std::path::Path;

use super::RawEntry;
use super::readers::read_json;
use crate::hook::command_stem;

/// How a registry spells "every operation": the matcher an entry with
/// none is named by, and the one spelling anything comparing a recorded
/// matcher with a read one has to use.
pub(crate) const ANY_MATCHER: &str = "*";

/// `{"hooks": {"<Event>": [{matcher?, hooks: [{command}]} | {command}]}}` —
/// claude settings.json and codex/cursor hooks.json share this shape; cursor
/// omits `matcher` and nests no handler array.
pub fn read(path: &Path) -> Result<Vec<RawEntry>, String> {
    let value = read_json(path)?;
    let Some(events) = value.get("hooks").and_then(|h| h.as_object()) else {
        return Ok(Vec::new());
    };
    let mut entries = Vec::new();
    for (event, groups) in events {
        let Some(groups) = groups.as_array() else {
            continue;
        };
        for group in groups {
            let matcher = group
                .get("matcher")
                .and_then(|m| m.as_str())
                .filter(|m| !m.is_empty())
                .unwrap_or(ANY_MATCHER);
            let handlers = match group.get("hooks").and_then(|h| h.as_array()) {
                Some(list) => list.iter().collect::<Vec<_>>(),
                None => vec![group],
            };
            for handler in handlers {
                let Some(command) = handler.get("command").and_then(|c| c.as_str()) else {
                    continue;
                };
                entries.push(RawEntry {
                    name: format!("{event}:{matcher}:{}", command_stem(command)),
                    enabled: None,
                    description: Some(command.to_owned()),
                    source_path: None,
                });
            }
        }
    }
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_and_cursor_shapes_both_parse() {
        let tmp = tempfile::tempdir().unwrap();
        let claude = tmp.path().join("settings.json");
        std::fs::write(
            &claude,
            r#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\""}]}]}}"#,
        )
        .unwrap();
        let entries = read(&claude).unwrap();
        assert_eq!(entries[0].name, "PreToolUse:Bash:guard");

        let cursor = tmp.path().join("hooks.json");
        std::fs::write(
            &cursor,
            r#"{"hooks":{"beforeShellExecution":[{"command":"./check.sh"}]}}"#,
        )
        .unwrap();
        let entries = read(&cursor).unwrap();
        assert_eq!(entries[0].name, "beforeShellExecution:*:check");
    }
}
