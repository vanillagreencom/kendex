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

/// The manifest text with the retired safety-decision tables cut out and
/// every other byte kept: the records decide nothing any more, and a
/// migration that rewrote the whole file to drop them would take the
/// reader's comments and formatting with it (invariant 10). Blank and
/// comment lines directly above a header introduce that table, so they go
/// with a retired one and stay with a kept one. Whatever this misreads —
/// a bracket opening a line inside a multi-line value — the caller's
/// reproduction check turns into the full rewrite, never a wrong file.
fn retire_safety_tables(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut preamble = String::new();
    let mut retiring = false;
    for line in text.split_inclusive('\n') {
        let body = line.trim();
        if body.is_empty() || body.starts_with('#') {
            preamble.push_str(line);
            continue;
        }
        if opens_table(line) {
            retiring = opens_retired_table(line);
        }
        if !retiring {
            out.push_str(&preamble);
            out.push_str(line);
        }
        preamble.clear();
    }
    out.push_str(&preamble);
    out
}

/// Upgrade an older-schema manifest through the normal journaled apply.
/// The bump is a surgical text edit — the schema line changes, the tables
/// schema 6 retired are cut out, and nothing else moves (invariant 10).
/// The edit must reproduce exactly the manifest the plan loaded; when it
/// cannot — no schema assignment to find, a table the cut did not
/// recognise — the full rewrite is the fallback that keeps the plan
/// correct at the cost of formatting.
pub(in crate::engine) fn plan_schema_upgrade(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    base: Option<&Base>,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let path = manifest::manifest_path(env, scope);
    let description = format!(
        "Upgrade {} to the current format",
        crate::rename::MANIFEST_FILE
    );
    let current = crate::fs::read_if_exists(&path)?.unwrap_or_default();
    let mut rewritten = false;
    let upgraded_text: String = retire_safety_tables(&current)
        .split_inclusive('\n')
        .map(|line| {
            let (body, newline) = match line.strip_suffix('\n') {
                Some(body) => (body, "\n"),
                None => (line, ""),
            };
            match rewritten {
                false => {
                    match rewrite_schema_line(body, manifest.schema, manifest::MANIFEST_SCHEMA) {
                        Some(new_body) => {
                            rewritten = true;
                            format!("{new_body}{newline}")
                        }
                        None => line.to_owned(),
                    }
                }
                true => line.to_owned(),
            }
        })
        .collect();
    // The one terminator repair a managed write makes (the #1308 class):
    // a file missing its final newline gains one, once, and every later
    // write is byte-stable.
    let mut upgraded_text = upgraded_text;
    if !upgraded_text.is_empty() && !upgraded_text.ends_with('\n') {
        upgraded_text.push('\n');
    }
    let mut upgraded = manifest.clone();
    upgraded.schema = manifest::MANIFEST_SCHEMA;
    let reproduced = rewritten
        && toml::from_str::<Manifest>(&upgraded_text).is_ok_and(|parsed| parsed == upgraded);
    let op = match reproduced {
        true => Op::WriteFile {
            pre: manifest_pre(base, &path)?,
            path,
            bytes: upgraded_text.into_bytes(),
        },
        false => Op::WriteManifest {
            pre: manifest_pre(base, &path)?,
            path,
            manifest: Box::new(upgraded),
        },
    };
    ops.push(PlannedOp { description, op });
    Ok(())
}

/// A `repo = "<old default>"` assignment rewritten to point at the new
/// repository with every other byte — indentation, spacing style, trailing
/// comment — kept. `None` for any other line, and for a value carrying
/// escapes: rewriting one safely is not worth it when the caller's
/// fallback write is still correct.
fn rewrite_repo_line(line: &str) -> Option<String> {
    let body = line.trim_start();
    let indent = &line[..line.len() - body.len()];
    let body = body.strip_prefix("repo")?;
    let after_key = body.trim_start();
    let key_ws = &body[..body.len() - after_key.len()];
    let after_eq = after_key.strip_prefix('=')?;
    let value = after_eq.trim_start();
    let eq_ws = &after_eq[..after_eq.len() - value.len()];
    let inner = value.strip_prefix('"')?;
    let (content, tail) = inner.split_once('"')?;
    if content.contains('\\') || !crate::repo_move::names_old_default(content) {
        return None;
    }
    Some(format!(
        "{indent}repo{key_ws}={eq_ws}\"{}\"{tail}",
        manifest::DEFAULT_SOURCE_REPO
    ))
}

/// The repository move as a surgical text edit: the file's bytes change
/// only where the old repository sits in a repo value position — and on
/// the schema line, with the retired safety tables cut out, when the
/// format is old — so comments, ordering, and formatting survive
/// (invariant 10). The edit must reproduce exactly the
/// manifest the plan computed; when it cannot — an inline table, a string
/// with escapes, another mutation riding the same plan — the full rewrite
/// is the fallback that keeps the plan correct at the cost of formatting.
pub(in crate::engine) fn plan_repo_move_write(
    env: &Env,
    scope: &Scope,
    migrated: &Manifest,
    base: Option<&Base>,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let path = manifest::manifest_path(env, scope);
    let mut expected = migrated.clone();
    expected.schema = manifest::MANIFEST_SCHEMA;
    let current = crate::fs::read_if_exists(&path)?.unwrap_or_default();
    let mut schema_done = migrated.schema == manifest::MANIFEST_SCHEMA;
    let mut edited: String = retire_safety_tables(&current)
        .split_inclusive('\n')
        .map(|line| {
            let (body, newline) = match line.strip_suffix('\n') {
                Some(body) => (body, "\n"),
                None => (line, ""),
            };
            if !schema_done
                && let Some(new_body) =
                    rewrite_schema_line(body, migrated.schema, manifest::MANIFEST_SCHEMA)
            {
                schema_done = true;
                return format!("{new_body}{newline}");
            }
            match rewrite_repo_line(body) {
                Some(new_body) => format!("{new_body}{newline}"),
                None => line.to_owned(),
            }
        })
        .collect();
    // The one terminator repair a managed write makes (the #1308 class):
    // a file missing its final newline gains one, once, and every later
    // write is byte-stable.
    if !edited.is_empty() && !edited.ends_with('\n') {
        edited.push('\n');
    }
    let reproduced = toml::from_str::<Manifest>(&edited).is_ok_and(|parsed| parsed == expected);
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
    ops.push(PlannedOp {
        description: crate::repo_move::MOVE_DESCRIPTION.into(),
        op,
    });
    Ok(())
}
