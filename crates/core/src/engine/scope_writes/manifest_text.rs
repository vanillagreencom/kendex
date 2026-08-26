//! The manifest as text: the two migrations a plan writes into
//! kendex.toml — the schema bump and the default repository's move — as
//! surgical edits that keep every byte they do not have to change
//! (invariant 10), each falling back to the full rewrite only when the
//! edit cannot reproduce the manifest the plan computed.

use super::manifest_pre;
use crate::apply::{Op, PlannedOp};
use crate::base::Base;
use crate::env::Env;
use crate::error::Result;
use crate::manifest::{self, Manifest};
use crate::model::Scope;

/// The schema assignment on one line, rewritten to the new value with every
/// other byte — indentation, spacing style, trailing comment — kept. None
/// when the line is not a plain `schema = <from>` integer assignment; a
/// comment that merely mentions the text must never match.
fn rewrite_schema_line(line: &str, from: u32, to: u32) -> Option<String> {
    let body = line.trim_start();
    let indent = &line[..line.len() - body.len()];
    let body = body.strip_prefix("schema")?;
    let after_key = body.trim_start();
    let key_ws = &body[..body.len() - after_key.len()];
    let after_eq = after_key.strip_prefix('=')?;
    let value = after_eq.trim_start();
    let eq_ws = &after_eq[..after_eq.len() - value.len()];
    let digits = value.len() - value.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    let (number, tail) = value.split_at(digits);
    if number != from.to_string() {
        return None;
    }
    if !(tail.trim_start().is_empty() || tail.trim_start().starts_with('#')) {
        return None;
    }
    Some(format!("{indent}schema{key_ws}={eq_ws}{to}{tail}"))
}

/// Whether this line opens one of the tables schema 6 retired —
/// `[safety-overrides…]` or `[safety-reviews…]`, any subtable included.
fn opens_retired_table(line: &str) -> bool {
    let Some(header) = line.trim_start().strip_prefix('[') else {
        return false;
    };
    let name = header.strip_prefix('[').unwrap_or(header).trim_start();
    ["safety-overrides", "safety-reviews"].iter().any(|table| {
        name.strip_prefix(table).is_some_and(|rest| {
            rest.starts_with([']', '.']) || rest.starts_with(char::is_whitespace)
        })
    })
}

/// Whether this line opens any table — where a retired table's block ends.
fn opens_table(line: &str) -> bool {
    line.trim_start().starts_with('[')
}

fn is_comment(line: &str) -> bool {
    line.trim_start().starts_with('#')
}

/// Where a retired header's own introduction starts inside the blank and
/// comment lines above it: the comment block touching the header, and the
/// blank lines above that. A comment block a blank line away is the
/// reader's own note, not the table's, and stays.
fn introduces(preamble: &[&str]) -> usize {
    let mut at = preamble.len();
    while at > 0 && is_comment(preamble[at - 1]) {
        at -= 1;
    }
    while at > 0 && preamble[at - 1].trim().is_empty() {
        at -= 1;
    }
    at
}

/// The manifest text with the retired safety-decision tables cut out and
/// every other byte kept: the records decide nothing any more, and a
/// migration that rewrote the whole file to drop them would take the
/// reader's comments and formatting with it (invariant 10). A retired
/// block takes its header, its lines, and the introduction above it (see
/// [`introduces`]); everything else, notes above a kept header included,
/// stays where it was written. Only the bracketed spellings are cut here —
/// a quoted header, a dotted key or an inline table passes through, and
/// the loader gate in [`surgical_manifest_write`] sends such a file to the
/// full rewrite rather than writing it under a schema that refuses it.
fn retire_safety_tables(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut preamble: Vec<&str> = Vec::new();
    let mut retiring = false;
    for line in text.split_inclusive('\n') {
        if line.trim().is_empty() || is_comment(line) {
            preamble.push(line);
            continue;
        }
        if opens_table(line) {
            retiring = opens_retired_table(line);
            if retiring {
                out.extend(preamble.drain(..introduces(&preamble)));
            }
        }
        if !retiring {
            out.extend(preamble.drain(..));
            out.push_str(line);
        }
        preamble.clear();
    }
    out.extend(preamble);
    out
}

/// One surgical write of the manifest: the retired tables cut out, the
/// schema line bumped, `edit_line` applied to every other line, and the
/// file's missing final newline repaired once (the #1308 class) — with
/// every byte the edit did not have to change kept. The edit is trusted
/// only when the loader reads it back as exactly the manifest the plan
/// computed at the current schema, so anything the text edit misread — a
/// retired table in a spelling the cut does not know, a bracket inside a
/// multi-line value — falls back to the full rewrite, which serializes the
/// manifest without the retired records. Never a wrong file: at worst a
/// reformatted one.
fn surgical_manifest_write(
    env: &Env,
    scope: &Scope,
    loaded: &Manifest,
    base: Option<&Base>,
    edit_line: impl Fn(&str) -> Option<String>,
    description: String,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let path = manifest::manifest_path(env, scope);
    let mut expected = loaded.clone();
    expected.schema = manifest::MANIFEST_SCHEMA;
    let current = crate::fs::read_if_exists(&path)?.unwrap_or_default();
    let mut schema_done = loaded.schema == manifest::MANIFEST_SCHEMA;
    let mut edited: String = retire_safety_tables(&current)
        .split_inclusive('\n')
        .map(|line| {
            let (body, newline) = match line.strip_suffix('\n') {
                Some(body) => (body, "\n"),
                None => (line, ""),
            };
            if !schema_done
                && let Some(new_body) =
                    rewrite_schema_line(body, loaded.schema, manifest::MANIFEST_SCHEMA)
            {
                schema_done = true;
                return format!("{new_body}{newline}");
            }
            match edit_line(body) {
                Some(new_body) => format!("{new_body}{newline}"),
                None => line.to_owned(),
            }
        })
        .collect();
    if !edited.is_empty() && !edited.ends_with('\n') {
        edited.push('\n');
    }
    let reproduced = schema_done
        && matches!(
            manifest::parse_text(&path, &edited),
            Ok(manifest::ManifestFile::Current(parsed)) if *parsed == expected
        );
    let op = match reproduced {
        true => Op::WriteFile {
            pre: manifest_pre(base, &path)?,
            path,
            bytes: edited.into_bytes(),
        },
        false => Op::WriteManifest {
            pre: manifest_pre(base, &path)?,
            path,
            manifest: Box::new(expected),
        },
    };
    ops.push(PlannedOp { description, op });
    Ok(())
}

/// Upgrade an older-schema manifest through the normal journaled apply:
/// the schema line and the retired tables, nothing else (invariant 10).
pub(in crate::engine) fn plan_schema_upgrade(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    base: Option<&Base>,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let description = format!(
        "Upgrade {} to the current format",
        crate::manifest::MANIFEST_FILE
    );
    surgical_manifest_write(env, scope, manifest, base, |_| None, description, ops)
}

#[cfg(test)]
mod tests {
    use super::retire_safety_tables;

    /// A retired block takes the comment touching its header and the blank
    /// lines above that; a note a blank line away is the reader's and
    /// stays. The header after the block keeps its own introduction.
    #[test]
    fn a_note_a_blank_line_above_a_retired_header_stays() {
        let text = "schema = 5\n\n[skills.gh]\nsource = \"cat\"\n\n# my notes\n# more notes\n\n# the overrides\n[safety-overrides.\"skill:gh:claude\"]\nreview-hash = \"abc\"\n\n# the fork stays\n[forks.skill.zed]\nsource = \"cat\"\n";
        assert_eq!(
            retire_safety_tables(text),
            "schema = 5\n\n[skills.gh]\nsource = \"cat\"\n\n# my notes\n# more notes\n\n# the fork stays\n[forks.skill.zed]\nsource = \"cat\"\n"
        );
    }

    /// Blank lines alone above the header go with it, and a block at the
    /// end of the file leaves the kept text ending where it did.
    #[test]
    fn blank_lines_above_a_retired_header_go_with_it() {
        let text = "schema = 5\n[skills.gh]\nsource = \"cat\"   # keep\n\n[safety-reviews.\"skill:gh:claude\"]\nruleset = 3\n\n[safety-reviews.\"skill:gh:claude\".dismissed.f2]\nreason = \"intended\"\n";
        assert_eq!(
            retire_safety_tables(text),
            "schema = 5\n[skills.gh]\nsource = \"cat\"   # keep\n"
        );
    }

    /// Only the bracketed spellings are cut here; the others reach the
    /// loader gate, which refuses them at the new schema.
    #[test]
    fn other_spellings_pass_through_to_the_gate() {
        let text =
            "schema = 5\nsafety-overrides = { x = 1 }\n[\"safety-reviews\".k]\nruleset = 3\n";
        assert_eq!(retire_safety_tables(text), text);
    }
}
