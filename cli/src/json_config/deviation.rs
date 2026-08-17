//! Checking a document against its [`Schema`], and NAMING the first value
//! that deviates.
//!
//! Split from the declarations for one reason: the message is the remedy. A
//! refusal here is handed to a user as the only thing that repairs their
//! config, so the walk carries the JSON path it is on and the failure says
//! which value, in which file, had to be what — never "the file is bad".

use super::Schema;
use anyhow::Result;
use std::path::Path;

pub(super) fn validate(path: &Path, schema: &Schema, doc: &serde_json::Value) -> Result<()> {
    if let Err(deviation) = check(schema, doc, "") {
        anyhow::bail!("{}: {deviation}", path.display());
    }
    Ok(())
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
        Schema::Bool => match value.is_boolean() {
            true => Ok(()),
            false => Err(deviation(at, "a boolean", value)),
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
