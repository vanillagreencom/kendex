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
//! Which makes the declaration itself the thing to get right: **every field
//! any reader here goes on to INTERPRET is declared with its real type.** A
//! read field left as [`Schema::Any`] is a field whose malformed value the
//! reader silently reinterprets as something else — a `"matcher": 42` read as
//! "no matcher", answering "registered" for a hook the harness cannot
//! deserialize and will never run. So `Any` is not the default here; it is
//! the claim that vstack only ever PRESERVES this value, and each one below
//! says which field it is making that claim about.
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

mod deviation;

use deviation::validate;

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
    /// and never interpreted — the deliberate opt-out, so that a shape this
    /// module does refuse is a shape a reader really depends on.
    ///
    /// Only for a value no reader draws a conclusion from. A field a reader
    /// DOES read gets its own type below, however obvious the type looks:
    /// left here, its malformed value is not refused but quietly reread as
    /// whatever the reader's fallback says, and every command downstream
    /// reports that reading as fact.
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
///
/// Every OTHER root key is `Any`: codex's `hooks.json` holds nothing else
/// vstack reads, and a writer round-trips what it finds there untouched.
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
/// `matcher` is DECLARED rather than left to `values` because the reader
/// interprets it: registration reading selects an entry by comparing this
/// value to the hook's own matcher, and anything that is not a string reads
/// there as "no matcher" — exactly the shape a MATCHERLESS hook's slot
/// accepts. Left as `Any`, a `"matcher": 42` neither harness can deserialize
/// answered `Registered` for a hook that would never fire, and `check` called
/// it clean. Absent stays absent: a matcherless entry is what a matcherless
/// hook registers as.
///
/// Every other key of an entry is `Any`: no reader consults one, and each is
/// content the writers carry across a rewrite unchanged.
static HOOK_ENTRY: Schema = Schema::Object {
    keys: &[
        ("matcher", &Schema::Str),
        ("hooks", &Schema::Array(&HOOK_HANDLER)),
    ],
    values: &Schema::Any,
};
/// `command` is the whole of what ownership is decided from, so it is typed.
/// `type` and `timeout` are `Any` deliberately: vstack WRITES both onto its
/// own handler and reads neither back out of the document, and refusing a
/// user's handler over a value nothing here consults is the too-strict half
/// of the same mistake.
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
/// Everything else in `settings.json` — permissions, env, model, status line —
/// is `Any`: vstack neither reads nor authors any of it, and every write here
/// carries it back out as it came in.
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
/// Both containers are typed, because both writers create and edit them.
///
/// What sits INSIDE them is `Any`, and per field:
///
/// - `instructions[]` — read as a string, to ask whether it names this hook's
///   instruction file. vstack only ever appends a string, so an element of
///   another type is somebody else's and cannot be the registration being
///   looked for. It reads as absent, which understates: the remedy is a
///   reinstall that appends the correct entry. Typing it would refuse the
///   whole config over an entry vstack does not own.
/// - `permission.<tool>` — only `permission.bash` is read, and only to ask
///   whether it is EXACTLY the `{"*": "ask"}` rule the installer writes.
///   Anything else, of any shape, is the user's and is left alone; install
///   likewise writes the rule only when the key is absent entirely. No
///   presence report rests on it.
/// - every other root key — OpenCode's own configuration, which vstack reads
///   nothing from.
///
/// None of the three can turn a malformed value into a claim that something
/// is installed, which is what separates them from `matcher` in [`HOOK_ENTRY`].
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
/// Only the `packages` array is vstack's, so only it is typed. What is inside
/// it is `Any` for the same reason opencode's entries are, per field:
///
/// - `packages[]` — read as a string path, or as an object whose `source` is
///   one. An entry of any other shape, and an object whose `source` is not a
///   string, cannot be the `./packages/<name>` vstack writes; it reads as
///   absent and every writer rebuilds the array preserving it.
/// - every other root key — Pi's own settings, which vstack reads nothing
///   from and rewrites verbatim.
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

#[cfg(test)]
mod tests;
