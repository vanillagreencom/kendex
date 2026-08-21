//! Which occurrences of a finding the publisher wrote, as opposed to the
//! project that installed it.
//!
//! Split out of `mod.rs`. The budget answers *how many* occurrences a
//! record paid for; this answers *which*, which is the half a count cannot
//! see — two occurrences of one sentence at one weight are the same to it,
//! and a project's own text goes in above the publisher's body.

use std::collections::{BTreeMap, BTreeSet};

use super::text;
use super::{AuditInput, Doc, Finding};

/// Which of these findings the publisher's own rendering also produced.
///
/// Two renderings of one item differ by exactly what the project
/// contributed, so a line the publisher's own rendering carries is theirs
/// wherever it turns up in the real one, and a line that is not there is
/// not. Nothing here reads the rendered text for markers: the comparison is
/// against the renderer's own answer for what the publisher wrote, which is
/// the same fact a budget is earned from.
///
/// This is *which*, where the budget is only *how many* — and how many is
/// not enough. Two occurrences of one sentence at one weight are
/// indistinguishable to a count, so it spends on whichever came first, and
/// a project's own instructions go in above the publisher's body. The
/// arithmetic came out right and the wrong line wore the publisher's name,
/// which is the disclosure the whole grant is justified by.
///
/// A finding about a document rather than a line — what deobfuscation had
/// to change, bytes that would not decode — is matched by its document.
/// What the publisher's own bytes carry of those is already all the budget
/// there is for them, so the count is what bounds those and this does not
/// have to.
pub fn authored_by(real: AuditInput, authored: AuditInput, findings: &[Finding]) -> Vec<bool> {
    let authored = text::prepare(authored);
    let theirs: BTreeSet<String> = authored
        .docs
        .iter()
        .map(|doc| doc.location.clone())
        .chain(
            text::prepare(real)
                .docs
                .iter()
                .flat_map(|doc| aligned(doc, &authored.docs)),
        )
        .collect();
    findings
        .iter()
        .map(|finding| theirs.contains(&finding.location))
        .collect()
}

/// The locations in one rendered document whose line the publisher wrote,
/// by walking it beside their own rendering of it.
///
/// What the project contributes is inserted, so the two documents agree
/// line for line except where it went in — and a line only counts as theirs
/// where it is *their* line in order, not merely a line reading the same.
/// That last part is the whole difficulty: a project can repeat a reviewed
/// sentence word for word, and then only its place among the lines around
/// it says whose it is.
///
/// The walk resynchronises rather than giving up: an input the project
/// replaces rather than adds — an agent's frontmatter override — leaves a
/// line of theirs with no counterpart, and skipping it keeps the rest of
/// the document aligned. A line nothing can be said about is not theirs,
/// so a record settles less rather than settling somebody else's line.
fn aligned(real: &Doc, authored: &[Doc]) -> Vec<String> {
    let Some(mine) = authored.iter().find(|doc| doc.location == real.location) else {
        return Vec::new();
    };
    let mut ahead: BTreeMap<&str, usize> = BTreeMap::new();
    for line in &real.lines {
        *ahead.entry(line.text.as_str()).or_default() += 1;
    }
    let mut at = 0;
    let mut found = Vec::new();
    for line in &real.lines {
        // Lines of theirs this document no longer holds are lines the
        // project replaced or the rendering dropped; stepping over them is
        // what keeps everything after this point aligned.
        while mine
            .lines
            .get(at)
            .is_some_and(|theirs| ahead.get(theirs.text.as_str()).copied().unwrap_or(0) == 0)
        {
            at += 1;
        }
        if mine
            .lines
            .get(at)
            .is_some_and(|theirs| theirs.text == line.text)
        {
            found.push(format!("{}:{}", real.location, line.number));
            at += 1;
        }
        if let Some(left) = ahead.get_mut(line.text.as_str()) {
            *left -= 1;
        }
    }
    found
}
