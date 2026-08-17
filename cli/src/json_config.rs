//! The JSON config files vstack SHARES with a harness — claude's
//! `settings.json`, codex's `hooks.json`, opencode's `opencode.json`, Pi's
//! `settings.json`. Every one of them is read to answer "is this installed?"
//! and written back to install or remove, and the user owns everything else
//! in them.
//!
//! **vstack never overwrites a value it could not understand.** One
//! validation, declared as data, answers both questions: a document that
//! deviates from the shape vstack depends on — anywhere on the path vstack
//! reads — is UNREADABLE, so the presence check reports it unverifiable
//! naming the file and the deviation, and every writer refuses it. Collapsing
//! that into "absent" is what reported a malformed file as a missing install
//! and then replaced the offending value with a default, discarding the
//! user's own content with it.
//!
//! The rule is the reason the schema is a whole-document declaration rather
//! than a probe at the one call site that noticed: a key added to [`Schema`]
//! is covered in the reader, in the presence check and in every writer at
//! once, so the next shape is covered by construction.

use anyhow::{Context, Result};
use std::path::Path;

/// What every writer here says when it will not touch a config it could not
/// parse. Shared so the refusal reads the same whichever file hit it.
pub(crate) const REFUSE_UNPARSEABLE_CONFIG: &str = "refusing to rewrite a config vstack cannot parse — every other setting and hook registration in it would be discarded; fix the file by hand, then rerun";

/// The shape a document must have where vstack reads or writes it.
///
/// A key that is ABSENT is a fact about the document, never a deviation: it
/// says the registration is not there, which is exactly what a presence check
/// wants to hear. Only a key that is PRESENT is held to its type.
pub(crate) enum Schema {
    /// Nothing here is on vstack's path. Any value at all, preserved as it is
    /// and never inspected — the deliberate opt-out, so that a shape this
    /// module does refuse is a shape a reader really depends on.
    Any,
    /// A JSON object. `keys` are the ones vstack reads by name; `values`
    /// constrains every other value, for the maps whose KEYS belong to the
    /// user (hook event names).
    Object {
        keys: &'static [(&'static str, &'static Schema)],
        values: &'static Schema,
    },
    /// An array, every element of which has this shape.
    Array(&'static Schema),
    /// A JSON string.
    Str,
}

/// `hooks → <event> → [{matcher?, hooks: [{command}]}]` — the document
/// claude's `settings.json` and codex's `hooks.json` share, and the whole of
/// what registration reading and both installers depend on.
pub(crate) static HOOKS_CONFIG: Schema = Schema::Object {
    keys: &[("hooks", &HOOK_EVENTS)],
    values: &Schema::Any,
};
/// Keyed by the harness's event names, which vstack does not enumerate here —
/// a config may register events vstack knows nothing about, and each of their
/// values is still an array a writer would otherwise replace.
static HOOK_EVENTS: Schema = Schema::Object {
    keys: &[],
    values: &Schema::Array(&HOOK_ENTRY),
};
static HOOK_ENTRY: Schema = Schema::Object {
    keys: &[("hooks", &Schema::Array(&HOOK_HANDLER))],
    values: &Schema::Any,
};
static HOOK_HANDLER: Schema = Schema::Object {
    keys: &[("command", &Schema::Str)],
    values: &Schema::Any,
};

/// opencode's `opencode.json`. `instructions` is appended to and filtered;
/// `permission` is merged into. Their ELEMENTS are `Any` on purpose: both
/// writers preserve every entry they do not recognize, and an entry that is
/// not the string vstack writes cannot be vstack's — absent is the true
/// answer there, not unreadable.
pub(crate) static OPENCODE_CONFIG: Schema = Schema::Object {
    keys: &[
        ("instructions", &Schema::Array(&Schema::Any)),
        (
            "permission",
            &Schema::Object {
                keys: &[],
                values: &Schema::Any,
            },
        ),
    ],
    values: &Schema::Any,
};

/// Pi's `settings.json`. Only the `packages` array is vstack's; an entry
/// inside it is `Any` for the same reason opencode's are — every writer
/// rebuilds the array preserving what it did not match, and an entry vstack
/// cannot interpret is not the one naming its own package directory.
pub(crate) static PI_SETTINGS: Schema = Schema::Object {
    keys: &[("packages", &Schema::Array(&Schema::Any))],
    values: &Schema::Any,
};

/// Read `path` as a JSON document of `schema`.
///
/// - `Ok(None)` — there is no file, or it holds nothing at all. A writer
///   starts from its own default; a reader has nothing to find.
/// - `Ok(Some(doc))` — every value on vstack's path is the shape it must be,
///   so readers and writers act on it without probing shapes again.
/// - `Err` — the file EXISTS and deviates: not valid JSON, or a value that is
///   not what the schema requires. Never a default document, and the message
///   names the file and the deviation so the report can hand the user the one
///   thing that repairs it.
pub(crate) fn read(path: &Path, schema: &Schema) -> Result<Option<serde_json::Value>> {
    let content = match std::fs::read_to_string(path) {
        Ok(content) => content,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err).with_context(|| format!("reading {}", path.display())),
    };
    if content.trim().is_empty() {
        return Ok(None);
    }
    let doc: serde_json::Value = serde_json::from_str(&content)
        .map_err(|err| anyhow::anyhow!("{} is not valid JSON: {err}", path.display()))?;
    if let Err(deviation) = check(schema, &doc, "") {
        anyhow::bail!("{}: {deviation}", path.display());
    }
    Ok(Some(doc))
}

/// The whole document against the whole schema. `at` is the JSON path walked
/// so far, so the failure names the value rather than the file alone.
fn check(schema: &Schema, value: &serde_json::Value, at: &str) -> Result<(), String> {
    match schema {
        Schema::Any => Ok(()),
        Schema::Str => match value.is_string() {
            true => Ok(()),
            false => Err(deviation(at, "a string", value)),
        },
        Schema::Array(element) => {
            let Some(items) = value.as_array() else {
                return Err(deviation(at, "an array", value));
            };
            for (index, item) in items.iter().enumerate() {
                check(element, item, &format!("{at}[{index}]"))?;
            }
            Ok(())
        }
        Schema::Object { keys, values } => {
            let Some(map) = value.as_object() else {
                return Err(deviation(at, "an object", value));
            };
            for (key, item) in map {
                let schema = keys
                    .iter()
                    .find(|(name, _)| *name == key.as_str())
                    .map_or(*values, |(_, schema)| *schema);
                check(schema, item, &child_path(at, key))?;
            }
            Ok(())
        }
    }
}

fn deviation(at: &str, expected: &str, found: &serde_json::Value) -> String {
    let at = if at.is_empty() { "the document" } else { at };
    format!("{at} is {}, expected {expected}", json_type(found))
}

fn json_type(value: &serde_json::Value) -> &'static str {
    match value {
        serde_json::Value::Null => "null",
        serde_json::Value::Bool(_) => "a boolean",
        serde_json::Value::Number(_) => "a number",
        serde_json::Value::String(_) => "a string",
        serde_json::Value::Array(_) => "an array",
        serde_json::Value::Object(_) => "an object",
    }
}

/// How long a key may run in a reported path. The key comes from the user's
/// file and the message rides into a drift report, which the renderer bounds
/// as a whole; bounding the segment keeps one absurd key from crowding out
/// the part of the path that identifies the fault.
const KEY_LIMIT: usize = 40;

fn child_path(at: &str, key: &str) -> String {
    let plain = !key.is_empty()
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | ':' | '|' | '.'));
    let mut shown: String = key.chars().take(KEY_LIMIT).collect();
    if shown.chars().count() < key.chars().count() {
        shown.push('…');
    }
    match (at.is_empty(), plain) {
        (true, true) => shown,
        (false, true) => format!("{at}.{shown}"),
        (_, false) => format!("{at}[{shown:?}]"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpfile(label: &str, content: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("vstack-json-config-{label}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.json");
        std::fs::write(&path, content).unwrap();
        path
    }

    fn refusal(content: &str) -> String {
        let path = tmpfile("refused", content);
        let err = read(&path, &HOOKS_CONFIG)
            .expect_err("a document that deviates from the schema must be an error");
        let _ = std::fs::remove_file(&path);
        format!("{err:#}")
    }

    /// Every shape on the read path, refused at the value that deviates —
    /// not at the outermost one that happens to be checked first.
    #[test]
    fn a_deviation_anywhere_on_the_path_names_itself() {
        for (document, expected) in [
            ("[]", "the document is an array, expected an object"),
            (r#"{"hooks": []}"#, "hooks is an array, expected an object"),
            (
                r#"{"hooks": {"SessionStart": {"command": "x"}}}"#,
                "hooks.SessionStart is an object, expected an array",
            ),
            (
                r#"{"hooks": {"SessionStart": ["bash x.sh"]}}"#,
                "hooks.SessionStart[0] is a string, expected an object",
            ),
            (
                r#"{"hooks": {"SessionStart": [{"hooks": {}}]}}"#,
                "hooks.SessionStart[0].hooks is an object, expected an array",
            ),
            (
                r#"{"hooks": {"SessionStart": [{"hooks": ["bash x.sh"]}]}}"#,
                "hooks.SessionStart[0].hooks[0] is a string, expected an object",
            ),
            (
                r#"{"hooks": {"SessionStart": [{"hooks": [{"command": 7}]}]}}"#,
                "hooks.SessionStart[0].hooks[0].command is a number, expected a string",
            ),
            (
                r#"{"hooks": {"PreToolUse:Bash": [1]}}"#,
                "hooks.PreToolUse:Bash[0] is a number, expected an object",
            ),
            (
                r#"{"hooks": {"odd key": 1}}"#,
                r#"hooks["odd key"] is a number, expected an array"#,
            ),
        ] {
            let message = refusal(document);
            assert!(
                message.contains(expected),
                "{document} must report {expected:?}: {message}"
            );
            assert!(
                message.contains("config.json"),
                "…and name the file: {message}"
            );
        }
    }

    /// The other half of the rule: everything a harness legitimately holds
    /// reads, so refusing is never the general case. A key vstack reads that
    /// is simply ABSENT is a document fact, not a deviation.
    #[test]
    fn a_document_off_vstacks_path_reads() {
        for document in [
            "{}",
            r#"{"model": "opus", "env": {"K": "V"}}"#,
            r#"{"hooks": {}}"#,
            r#"{"hooks": {"SessionStart": []}}"#,
            r#"{"hooks": {"SessionStart": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash x.sh", "timeout": 30}]}]}}"#,
            // An entry with no handlers at all, and a handler with no
            // command: neither can be vstack's registration, and no writer
            // replaces either.
            r#"{"hooks": {"Stop": [{"matcher": "*"}]}}"#,
            r#"{"hooks": {"Stop": [{"hooks": [{"type": "future"}]}]}}"#,
        ] {
            let path = tmpfile("accepted", document);
            let doc = read(&path, &HOOKS_CONFIG)
                .unwrap_or_else(|err| panic!("{document} must read: {err:#}"));
            assert!(doc.is_some(), "{document} must read as a document");
            let _ = std::fs::remove_file(&path);
        }
    }

    /// A missing file and an empty one are the same absence, and neither is
    /// an error: a writer starts from its own default.
    #[test]
    fn a_missing_or_empty_file_is_absent_not_unreadable() {
        let path = tmpfile("empty", "   \n");
        assert!(read(&path, &HOOKS_CONFIG).unwrap().is_none());
        std::fs::remove_file(&path).unwrap();
        assert!(read(&path, &HOOKS_CONFIG).unwrap().is_none());
    }

    /// A key long enough to crowd out the path it sits in is shortened, and
    /// the path around it survives.
    #[test]
    fn a_long_key_is_bounded_in_the_reported_path() {
        let key = "k".repeat(200);
        let message = refusal(&format!(r#"{{"hooks": {{"{key}": 1}}}}"#));
        assert!(message.contains("…"), "the key is elided: {message}");
        assert!(
            message.len() < 200,
            "the reported path stays bounded: {message}"
        );
        assert!(
            message.contains("expected an array"),
            "and still says what was wrong: {message}"
        );
    }
}
