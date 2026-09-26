//! What a plan's report draws before anything asks the reader, in the
//! order a reader acts on it: the conflicts that stopped an install, then
//! the packages safety found something in, then the notes. What needs no
//! attention — a clean package, a hook its own header keeps off a tool
//! nothing asked it onto, a finding's other sites, what the rules read past
//! — is left out of a compact report, so refresh's closing ledger can say
//! detail was left out and which flag shows it.
//!
//! A line said the same way many times is said once: one note class with
//! the same consequence across many packages is one row naming each of
//! them.

use kendex_core::engine::{EngineReport, ExcludedHook};
use kendex_core::env::Env;

use super::advisory::{Listing, safety_section};
use super::blocked::{conflict_rows, conflicts, drift};
use super::offers::{Blocked, blocked_items};
use crate::ui::{self, Span, Status, Style};

/// What the report drew, besides its lines.
#[derive(Default)]
pub struct Attention {
    /// The items the plan refused, read once for the lines drawn and the
    /// closing ledger's count alike.
    pub blocked: Vec<Blocked>,
    /// Whether a compact report left out anything a verbose run draws.
    /// Read off the two drawings themselves, never counted beside them, so
    /// it cannot miss a kind of line the verbose drawing adds. False on a
    /// verbose run, which draws it all.
    pub folded: bool,
}

/// Draw the report on stderr, as much of it as `listing` asks for. A
/// verbose run lists every drift row where the others list the conflicts,
/// and the hook exclusions as one line.
pub fn print_attention(env: &Env, report: &EngineReport, listing: Listing) -> Attention {
    let (lines, attention) = attention(&ui::style(), env, report, listing);
    ui::stderr(&lines);
    attention
}

fn attention(
    style: &Style,
    env: &Env,
    report: &EngineReport,
    listing: Listing,
) -> (Vec<String>, Attention) {
    let rows = conflict_rows(report);
    let blocked = blocked_items(env, &rows);
    let draw = |listing: Listing| {
        let verbose = listing == Listing::Verbose;
        let mut lines = match verbose {
            true => drift(style, report, &rows, &blocked),
            false => conflicts(style, report, &rows, &blocked),
        };
        lines.extend(safety_section(style, &report.safety, listing));
        lines.extend(notes_section(
            style,
            &report.notes,
            &report.excluded_hooks,
            verbose,
        ));
        lines
    };
    let lines = draw(listing);
    let folded = listing == Listing::Attention && draw(Listing::Verbose) != lines;
    (lines, Attention { blocked, folded })
}

/// What the plan wrote about itself. A note is its record line and the
/// sentences under it, each on a line of its own one level down. Notes of
/// one class that say the same thing under their record are one row naming
/// every record. The hook exclusions no declaration contradicts are one
/// row on a verbose run and none on a compact one.
fn notes_section(
    style: &Style,
    notes: &[String],
    excluded: &[ExcludedHook],
    verbose: bool,
) -> Vec<String> {
    let groups = grouped_notes(notes);
    let exclusions = match (verbose, excluded.is_empty()) {
        (true, false) => Some(exclusions_line(excluded)),
        _ => None,
    };
    let count = groups.len() + usize::from(exclusions.is_some());
    if count == 0 {
        return Vec::new();
    }
    let mut lines = style.section("notes", count, Status::Notice);
    for group in &groups {
        lines.extend(style.row(Status::Notice, &[Span::Prose(&group.head())], None));
        for line in &group.under {
            lines.extend(style.detail(None, &[Span::Prose(line)]));
        }
    }
    if let Some(exclusions) = exclusions {
        lines.extend(style.row(Status::Notice, &[Span::Prose(&exclusions)], None));
    }
    lines
}

/// Notes that fold into one row: one class, and the same lines under
/// every record.
struct NoteGroup<'a> {
    class: &'a str,
    records: Vec<&'a str>,
    under: Vec<&'a str>,
}

impl NoteGroup<'_> {
    /// The record itself for one note, and for several the class, how
    /// many, and what each record names.
    fn head(&self) -> String {
        match self.records.as_slice() {
            [one] => (*one).to_owned(),
            many => {
                let named: Vec<&str> = many
                    .iter()
                    .map(|record| {
                        record
                            .strip_prefix(self.class)
                            .and_then(|rest| rest.strip_prefix(": "))
                            .unwrap_or(record)
                    })
                    .collect();
                format!("{}, {} times: {}", self.class, many.len(), named.join("; "))
            }
        }
    }
}

/// Each note split at its own breaks, then grouped. The class is the
/// record's `kendex-…` key where the note opens with one; a note without
/// one is its own class, so only notes that are the same text fold.
fn grouped_notes(notes: &[String]) -> Vec<NoteGroup<'_>> {
    let mut groups: Vec<NoteGroup<'_>> = Vec::new();
    for note in notes {
        let mut lines = note.split('\n');
        let record = lines.next().unwrap_or_default();
        let under: Vec<&str> = lines.collect();
        let class = match record.split_once(": ") {
            Some((key, _)) if key.starts_with("kendex-") => key,
            _ => record,
        };
        match groups
            .iter_mut()
            .find(|group| group.class == class && group.under == under)
        {
            Some(group) => {
                if !group.records.contains(&record) {
                    group.records.push(record);
                }
            }
            None => groups.push(NoteGroup {
                class,
                records: vec![record],
                under,
            }),
        }
    }
    groups
}

/// The exclusions as one line: how many hooks, and each with the tools
/// its own harnesses line leaves out.
fn exclusions_line(excluded: &[ExcludedHook]) -> String {
    let mut hooks: Vec<(&str, Vec<&str>)> = Vec::new();
    for hook in excluded {
        let tool = hook.harness.name();
        match hooks.iter_mut().find(|(name, _)| *name == hook.name) {
            Some((_, tools)) => tools.push(tool),
            None => hooks.push((&hook.name, vec![tool])),
        }
    }
    let named: Vec<String> = hooks
        .iter()
        .map(|(name, tools)| format!("{name} ({})", tools.join(", ")))
        .collect();
    format!(
        "{} hook{} not written for the tools {} own harnesses line leaves out: {}",
        hooks.len(),
        match hooks.len() {
            1 => "",
            _ => "s",
        },
        match hooks.len() {
            1 => "its",
            _ => "their",
        },
        named.join(", ")
    )
}

#[cfg(test)]
mod tests;
