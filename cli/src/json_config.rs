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
//!
//! [`Syntax`] is declared beside the schema for the same reason. Which parser
//! a file needs is a fact about the harness that loads it, and reading a file
//! with a parser its harness does not use is wrong in both directions: too
//! strict reports a config the harness runs happily as unreadable, and too
//! loose accepts one the harness ignores and then rewrites it.

use anyhow::{Context, Result};
use jsonc_parser::ParseOptions;
use jsonc_parser::cst::CstRootNode;
use std::path::Path;

/// What every writer here says when it will not touch a config it could not
/// parse. Shared so the refusal reads the same whichever file hit it.
pub(crate) const REFUSE_UNPARSEABLE_CONFIG: &str = "refusing to rewrite a config vstack cannot parse — every other setting and hook registration in it would be discarded; fix the file by hand, then rerun";

/// The grammar the HARNESS reads a config with — never the one its file name
/// suggests.
///
/// The spelling is not the syntax. OpenCode hands `opencode.json` and
/// `opencode.jsonc` to one JSONC parser, so a comment in EITHER is content
/// OpenCode honors; claude, codex and Pi hand their `.json` to a strict
/// parser that rejects the same comment. Keying the decision off the
/// extension would report a working `opencode.jsonc` as unreadable, block
/// install and removal on it, and still mis-read the `opencode.json` beside
/// it.
pub(crate) enum Syntax {
    /// JSON as `serde_json` reads it. A comment here is a file the harness
    /// itself refuses, so vstack refuses it too.
    Strict,
    /// JSON plus comments and trailing commas — and nothing else. The other
    /// JSON5-ward relaxations stay OFF: accepting a single-quoted string or a
    /// hex number that OpenCode's own parser rejects would read a config the
    /// harness silently ignores as live, and then rewrite it.
    Jsonc,
}

/// One config file vstack shares with a harness: the grammar it is read with
/// and the shape vstack depends on inside it, declared together so a reader,
/// a presence check and a writer cannot disagree about either.
pub(crate) struct ConfigFile {
    pub(crate) syntax: Syntax,
    pub(crate) schema: &'static Schema,
}

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
    /// A JSON boolean.
    Bool,
}

/// Codex's `hooks.json` — strict JSON: codex deserializes it with serde and
/// registers no `.jsonc` spelling, so a comment in it is a file codex drops.
pub(crate) static HOOKS_CONFIG: ConfigFile = ConfigFile {
    syntax: Syntax::Strict,
    schema: &HOOK_DOCUMENT,
};

/// `hooks → <event> → [{matcher?, hooks: [{command}]}]` — the document
/// claude's `settings.json` and codex's `hooks.json` share, and the whole of
/// what registration reading and both installers depend on.
static HOOK_DOCUMENT: Schema = Schema::Object {
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

/// Claude's `settings.json`: the shared hooks document, plus the one other key
/// on vstack's read path — `disableAllHooks`, the documented switch that
/// decides whether claude runs any of what `hooks` registers. It is held to
/// its declared type like every other value here, so a `"true"` or a `1`
/// claude itself would not honor is UNREADABLE rather than silently taken as
/// "hooks are on".
///
/// Codex's `hooks.json` keeps [`HOOKS_CONFIG`]: the switch is not a key codex
/// defines, and holding another harness's file to it would refuse a document
/// codex reads perfectly well.
///
/// Strict, like codex's: claude's load order is `settings.json` and
/// `settings.local.json`, both handed to a strict parser, with no `.jsonc`
/// spelling anywhere in it.
pub(crate) static CLAUDE_SETTINGS: ConfigFile = ConfigFile {
    syntax: Syntax::Strict,
    schema: &CLAUDE_DOCUMENT,
};

static CLAUDE_DOCUMENT: Schema = Schema::Object {
    keys: &[("hooks", &HOOK_EVENTS), ("disableAllHooks", &Schema::Bool)],
    values: &Schema::Any,
};

/// OpenCode's config, whichever of its spellings this scope resolved to.
///
/// JSONC for all of them. OpenCode reads `opencode.json`, `opencode.jsonc`,
/// the global `config.json` and whatever `$OPENCODE_CONFIG` names through one
/// loader that parses with comments and trailing commas allowed, and drops a
/// file outright on any other syntax error. So a comment is content OpenCode
/// honors and vstack must carry across a write — not a defect in the file.
pub(crate) static OPENCODE_CONFIG: ConfigFile = ConfigFile {
    syntax: Syntax::Jsonc,
    schema: &OPENCODE_DOCUMENT,
};

/// `instructions` is appended to and filtered; `permission` is merged into.
/// Their ELEMENTS are `Any` on purpose: both writers preserve every entry they
/// do not recognize, and an entry that is not the string vstack writes cannot
/// be vstack's — absent is the true answer there, not unreadable.
static OPENCODE_DOCUMENT: Schema = Schema::Object {
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

/// Pi's `settings.json` — strict JSON: Pi's settings manager reads it with
/// `JSON.parse`, so a comment there is a file Pi refuses to start on.
///
/// Only the `packages` array is vstack's; an entry inside it is `Any` for the
/// same reason opencode's are — every writer rebuilds the array preserving
/// what it did not match, and an entry vstack cannot interpret is not the one
/// naming its own package directory.
pub(crate) static PI_SETTINGS: ConfigFile = ConfigFile {
    syntax: Syntax::Strict,
    schema: &PI_DOCUMENT,
};

static PI_DOCUMENT: Schema = Schema::Object {
    keys: &[("packages", &Schema::Array(&Schema::Any))],
    values: &Schema::Any,
};

/// Read `path` as a document of `config`.
///
/// - `Ok(None)` — there is no file, or it holds no value at all: empty, or
///   (for a [`Syntax::Jsonc`] file) nothing but comments, which is a document
///   its own harness loads nothing from. A reader has nothing to find.
/// - `Ok(Some(doc))` — every value on vstack's path is the shape it must be,
///   so readers and writers act on it without probing shapes again.
/// - `Err` — the file EXISTS and deviates: not valid in its own syntax, or a
///   value that is not what the schema requires. Never a default document,
///   and the message names the file and the deviation so the report can hand
///   the user the one thing that repairs it.
///
/// This is the READ answer. A writer wanting to edit a file without
/// discarding what it did not author goes through [`read_editable`] instead.
pub(crate) fn read(path: &Path, config: &ConfigFile) -> Result<Option<serde_json::Value>> {
    let Some(content) = read_content(path)? else {
        return Ok(None);
    };
    let doc = match config.syntax {
        Syntax::Strict => Some(
            serde_json::from_str(&content)
                .map_err(|err| anyhow::anyhow!("{} is not valid JSON: {err}", path.display()))?,
        ),
        Syntax::Jsonc => parse_jsonc(&content, path)?
            .value()
            .and_then(|value| value.to_serde_value()),
    };
    let Some(doc) = doc else {
        return Ok(None);
    };
    validate(path, config.schema, &doc)?;
    Ok(Some(doc))
}

/// The same document in the form a writer edits: a syntax tree that
/// re-renders byte-for-byte until something is changed, so every comment,
/// blank line and key order the user wrote outlives the edit.
///
/// `Ok(None)` means only that there is nothing on disk to edit — a writer
/// starts from its own default. A file holding nothing but comments still
/// comes back as a document, because writing a default over it would discard
/// exactly what this function exists to keep.
pub(crate) fn read_editable(path: &Path, config: &ConfigFile) -> Result<Option<CstRootNode>> {
    let Some(content) = read_content(path)? else {
        return Ok(None);
    };
    let root = parse_jsonc(&content, path)?;
    if let Some(doc) = root.value().and_then(|value| value.to_serde_value()) {
        validate(path, config.schema, &doc)?;
    }
    Ok(Some(root))
}

/// `Ok(None)` when there is no file or it holds nothing but whitespace.
fn read_content(path: &Path) -> Result<Option<String>> {
    let content = match std::fs::read_to_string(path) {
        Ok(content) => content,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err).with_context(|| format!("reading {}", path.display())),
    };
    match content.trim().is_empty() {
        true => Ok(None),
        false => Ok(Some(content)),
    }
}

fn parse_jsonc(content: &str, path: &Path) -> Result<CstRootNode> {
    CstRootNode::parse(content, &JSONC)
        .map_err(|err| anyhow::anyhow!("{} is not valid JSONC: {err}", path.display()))
}

/// Exactly the deviations OpenCode's own loader allows — comments and
/// trailing commas — with every remaining JSON5-ward relaxation the crate
/// defaults ON turned back OFF. A single-quoted string or a hex number is a
/// syntax error OpenCode drops the whole file on, so accepting one here would
/// read a config the harness ignores as live and then rewrite it.
pub(crate) const JSONC: ParseOptions = ParseOptions {
    allow_comments: true,
    allow_trailing_commas: true,
    allow_loose_object_property_names: false,
    allow_missing_commas: false,
    allow_single_quoted_strings: false,
    allow_hexadecimal_numbers: false,
    allow_unary_plus_numbers: false,
};

fn validate(path: &Path, schema: &Schema, doc: &serde_json::Value) -> Result<()> {
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

#[cfg(test)]
mod tests;
