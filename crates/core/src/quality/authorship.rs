//! Which occurrences of a finding the publisher wrote, as opposed to the
//! project that installed it.
//!
//! Split out of `mod.rs`. The budget answers *how many* occurrences a
//! record paid for; this answers *which*, which is the half a count cannot
//! see — two occurrences of one sentence at one weight are the same to it,
//! and a project's own text goes in above the publisher's body.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use super::text;
use super::{AuditInput, Content, Doc, Finding};

/// How the publisher's half of a rendering is known, as the builder that
/// rendered it says. Never read back out of the rendered text: text a
/// project supplied can be written to look like anything.
#[derive(Debug, Clone, PartialEq)]
pub enum Authored {
    /// The rendering is the publisher's own content with one block of the
    /// project's put into it, and this is where that block landed.
    /// Everything outside it is theirs — wherever the rendering moved it
    /// to, which is what a body-cap split does to a long skill. `None`
    /// where the project put nothing in and the whole of it is theirs.
    Around(Option<Injection>),
    /// The rendering is generated from inputs rather than assembled around
    /// the publisher's own file, so there is no block to point at: their
    /// half is a second rendering, from their inputs alone.
    Rendered {
        publishers: Content,
        /// The text the project handed the renderer, line by line. Prose
        /// reaches the document as lines of its own, so it is the one
        /// contribution that can read the same as a line of the
        /// publisher's; every other input is a value inside a line the
        /// renderer writes, and can only read the same when it *is* what
        /// the publisher wrote.
        supplied: BTreeSet<String>,
    },
}

/// Where a project's block sits in a rendered artifact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Injection {
    /// The file within the artifact, relative to its root.
    pub file: PathBuf,
    /// The first and last line the block occupies, counted from one and
    /// both inside it.
    pub lines: (usize, usize),
}

/// The publisher's half of one set of findings: which of them are theirs,
/// and the findings a record is measured against.
pub struct Publishers {
    /// One flag per finding, in the findings' own order.
    pub theirs: Vec<bool>,
    pub findings: Vec<Finding>,
}

/// Which of these findings are the publisher's, and what their record has
/// to answer for.
///
/// Both halves come out of one derivation because they are one question. A
/// count on its own is not enough — two occurrences of one sentence at one
/// weight are indistinguishable to it, so it spends on whichever came
/// first, and a project's own text goes in above the publisher's body. The
/// arithmetic came out right and the wrong line wore the publisher's name,
/// which is the disclosure the whole grant is justified by.
pub fn publishers(real: AuditInput, authored: &Authored, findings: &[Finding]) -> Publishers {
    let theirs: Vec<bool> = match authored {
        // A boundary, not a comparison. The artifact is the publisher's own
        // content with the block put into it, so everything outside the
        // block is theirs however far the rendering carried it — including
        // into a supporting file, where it weighs one step less. Reading
        // the weight off the artifact in front of us is the point: it is
        // the weight being scored.
        Authored::Around(block) => findings
            .iter()
            .map(|finding| !holds(block.as_ref(), &real.location, &finding.location))
            .collect(),
        Authored::Rendered {
            publishers,
            supplied,
        } => {
            let mine = AuditInput {
                content: publishers.clone(),
                ..real.clone()
            };
            let theirs = spoken_for(real, mine, supplied);
            findings
                .iter()
                .map(|finding| theirs.contains(&finding.location))
                .collect()
        }
    };
    let mine = findings
        .iter()
        .zip(&theirs)
        .filter(|(_, ours)| **ours)
        .map(|(finding, _)| finding.clone())
        .collect();
    Publishers {
        theirs,
        findings: mine,
    }
}

/// Whether a finding sits inside the project's block.
///
/// A location naming the whole document that holds the block counts as
/// inside it: a judgement about a document is not about the publisher's
/// bytes alone once the project's are in it. A document whose path merely
/// begins the same way is a different document.
fn holds(block: Option<&Injection>, root: &str, location: &str) -> bool {
    let Some(block) = block else {
        return false;
    };
    let Some(rest) = location.strip_prefix(&format!("{root}/{}", block.file.display())) else {
        return false;
    };
    match rest.strip_prefix(':') {
        Some(number) => number
            .parse::<usize>()
            .is_ok_and(|line| (block.lines.0..=block.lines.1).contains(&line)),
        None => rest.is_empty(),
    }
}

/// The locations in a generated rendering the publisher's own rendering
/// also speaks for, found by walking the two documents beside each other.
///
/// A finding about a document rather than a line — what deobfuscation had
/// to change, bytes that would not decode — is matched by its document.
/// What the publisher's own bytes carry of those is already all the budget
/// there is for them, so the count is what bounds those and this does not
/// have to.
fn spoken_for(real: AuditInput, mine: AuditInput, supplied: &BTreeSet<String>) -> BTreeSet<String> {
    let mine = text::prepare(mine);
    mine.docs
        .iter()
        .map(|doc| doc.location.clone())
        .chain(
            text::prepare(real)
                .docs
                .iter()
                .flat_map(|doc| aligned(doc, &mine.docs, supplied)),
        )
        .collect()
}

/// The locations in one rendered document whose line the publisher wrote,
/// by walking it beside their own rendering of it.
///
/// What the project contributes is inserted, so the two documents agree
/// line for line except where it went in — and a line only counts as theirs
/// where it is *their* line in order, not merely a line reading the same.
/// That last part is the whole difficulty: a project can repeat a reviewed
/// sentence word for word, and then order alone cannot say whose it is,
/// since the repeat comes first. So a line the project supplied is skipped
/// outright — neither counted as theirs nor allowed to stand in for one of
/// theirs — and the publisher's own occurrence further down is the one that
/// matches.
///
/// The walk resynchronises rather than giving up: an input the project
/// replaces rather than adds — an agent's frontmatter override — leaves a
/// line of theirs with no counterpart, and skipping it keeps the rest of
/// the document aligned. A line nothing can be said about is not theirs,
/// so a record settles less rather than settling somebody else's line.
fn aligned(real: &Doc, authored: &[Doc], supplied: &BTreeSet<String>) -> Vec<String> {
    let Some(mine) = authored.iter().find(|doc| doc.location == real.location) else {
        return Vec::new();
    };
    let ours = |line: &text::Line| !supplied.contains(line.text.as_str());
    let mut ahead: BTreeMap<&str, usize> = BTreeMap::new();
    for line in real.lines.iter().filter(|line| ours(line)) {
        *ahead.entry(line.text.as_str()).or_default() += 1;
    }
    let mut at = 0;
    let mut found = Vec::new();
    for line in real.lines.iter().filter(|line| ours(line)) {
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
