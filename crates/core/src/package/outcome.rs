//! What a plan did to one package, read off its own record.
//!
//! A conflict is per rendering and does not say by itself what became of
//! the copy: one with the person's work in it is kept exactly where it is,
//! one without goes to the trash with nothing written back. Three answers,
//! not two, and every surface that reports on a single-package update
//! reads them here.

use crate::engine::{DriftRow, DriftState, EngineReport};
use crate::model::ItemKind;

/// The installations of one package a plan refuses to write, kept exactly
/// as they are: a copy somebody edited, files kendex never put there, a
/// provenance clash. A conflict belongs to one rendering, so a package
/// that comes current in one tool while its copy in another is held
/// answers with the held one alone — read off the whole plan instead, and
/// the same run reports "nothing moved" over work it just did.
///
/// A conflict on its own does not say the copy stayed: a refusal with
/// nothing of the person's in the files takes the old installation to the
/// trash and writes nothing in its place. Those are [`removed`], and
/// calling them held would report a destructive run as one where nothing
/// happened.
pub fn held_back<'a>(report: &'a EngineReport, kind: ItemKind, name: &str) -> Vec<&'a DriftRow> {
    refused(report, kind, name)
        .into_iter()
        .filter(|row| !dropped(report, row))
        .collect()
}

/// The installations of one package a plan takes off disk without putting
/// anything back: refused, with no edits of the person's to keep, so the
/// old copy goes to the trash and the refusal is all that is left.
pub fn removed<'a>(report: &'a EngineReport, kind: ItemKind, name: &str) -> Vec<&'a DriftRow> {
    refused(report, kind, name)
        .into_iter()
        .filter(|row| dropped(report, row))
        .collect()
}

/// The installations of one package a plan writes: what is not there yet,
/// and what no longer matches its source. Every other row for it is either
/// refused or nothing this plan acts on.
pub fn moving<'a>(report: &'a EngineReport, kind: ItemKind, name: &str) -> Vec<&'a DriftRow> {
    package_rows(report, kind, name, |state| {
        matches!(state, DriftState::Missing | DriftState::Stale)
    })
}

/// Every rendering of this package the plan will not write.
fn refused<'a>(report: &'a EngineReport, kind: ItemKind, name: &str) -> Vec<&'a DriftRow> {
    package_rows(report, kind, name, |state| state == DriftState::Conflict)
}

/// Whether the plan takes this exact rendering out of the installed set.
/// Read off the set changes the plan itself computed — the record losing
/// the entry is what "the copy is gone" means — rather than off the
/// conflict's cause or the words of its detail, which happen to separate
/// the two shapes today and would stop the day either changes.
fn dropped(report: &EngineReport, row: &DriftRow) -> bool {
    report.set_changes.iter().any(|change| {
        change.direction == crate::engine::SetDirection::Remove
            && change.kind == row.kind
            && change.name == row.name
            && change.harness == row.harness
    })
}

fn package_rows<'a>(
    report: &'a EngineReport,
    kind: ItemKind,
    name: &str,
    wanted: impl Fn(DriftState) -> bool,
) -> Vec<&'a DriftRow> {
    report
        .drift
        .iter()
        .filter(|row| row.kind == kind && row.name == name && wanted(row.state))
        .collect()
}
