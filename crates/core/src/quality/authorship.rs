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
        /// The text the project handed the renderer, line by line, as it
        /// stands in the manifest. Prose reaches the document as lines of
        /// its own, so it is the one contribution that can read the same as
        /// a line of the publisher's; every other input is a value inside a
        /// line the renderer writes, and can only read the same when it
        /// *is* what the publisher wrote.
        ///
        /// Read here through the same deobfuscation the lines it is
        /// compared against went through — see [`spoken_for`].
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
        Authored::Around(block) => {
            let theirs = covered(block.as_ref(), &real.location);
            findings
                .iter()
                .map(|finding| !theirs.contains(&finding.location))
                .collect()
        }
        Authored::Rendered {
            publishers,
            supplied,
        } => {
            let input = AuditInput {
                content: publishers.clone(),
                ..real.clone()
            };
            // Their own rendering, read twice: what it produces, and what
            // of it survived into this one.
            let produced = crate::quality::audit(input.clone()).findings;
            let mine = text::prepare(input);
            let docs: BTreeSet<&str> = mine.docs.iter().map(|doc| doc.location.as_str()).collect();
            let lines = spoken_for(real, &mine.docs, supplied);
            findings
                .iter()
                .map(|finding| match docs.contains(finding.location.as_str()) {
                    // A whole document — what deobfuscation had to change,
                    // bytes that would not decode. Theirs when their own
                    // rendering produced this very finding, never merely
                    // because the document is in both: a project that swaps
                    // one of their occurrences for one of its own leaves a
                    // document that still exists and a sentence about it
                    // that still reads the same.
                    true => produced.iter().any(|mine| {
                        mine.location == finding.location
                            && mine.fingerprint() == finding.fingerprint()
                    }),
                    false => lines.contains(&finding.location),
                })
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

/// Every location the project's block covers, spelled the way a finding
/// spells its own.
///
/// Built rather than matched. A location is composed from a path a catalog
/// chose and a line number, so taking one apart again to read the number
/// off it is reading a catalog's filename as a line — the same shape as
/// reading a project's text for the block's edges. Composing the block's
/// own locations and comparing whole strings has nothing to take apart.
///
/// The document holding the block is one of them: a judgement about a whole
/// document is not about the publisher's bytes alone once the project's are
/// in it.
fn covered(block: Option<&Injection>, root: &str) -> BTreeSet<String> {
    let Some(block) = block else {
        return BTreeSet::new();
    };
    let doc = format!("{root}/{}", block.file.display());
    let mut covered: BTreeSet<String> = (block.lines.0..=block.lines.1)
        .map(|line| format!("{doc}:{line}"))
        .collect();
    covered.insert(doc);
    covered
}

/// The lines of a generated rendering the publisher's own rendering also
/// speaks for, found by walking the two documents beside each other.
///
/// Lines only. A finding naming a whole document is not a line and is not
/// answered here.
fn spoken_for(real: AuditInput, mine: &[Doc], supplied: &BTreeSet<String>) -> BTreeSet<String> {
    // Both sides of the comparison in one text space. What is compared is
    // the deobfuscated line, so a project repeating a reviewed sentence
    // with a zero-width character in it matches the publisher's line while
    // a set of raw manifest text never sees it — the pass that exists to
    // catch hidden characters carrying the attack across.
    let supplied: BTreeSet<String> = supplied
        .iter()
        .map(|line| text::deobfuscate("", line).0)
        .collect();
    text::prepare(real)
        .docs
        .iter()
        .flat_map(|doc| aligned(doc, mine, &supplied))
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

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::model::ItemKind;

    fn document(text: &str) -> AuditInput {
        AuditInput {
            kind: ItemKind::Agent,
            name: "helper".to_owned(),
            harness: None,
            location: "agents/helper.md".to_owned(),
            content: Content::Document {
                text: text.to_owned(),
            },
        }
    }

    fn rendered(text: &str) -> Authored {
        Authored::Rendered {
            publishers: Content::Document {
                text: text.to_owned(),
            },
            supplied: BTreeSet::new(),
        }
    }

    /// A finding that names a whole document belongs to the publisher when
    /// their own rendering produces it — not when their rendering merely
    /// has a document by that name.
    ///
    /// Reading it off the document's existence says a project's hidden
    /// characters are the publisher's the moment the publisher has a
    /// document to hide them in, and the budget then counts an occurrence
    /// nothing of theirs carried.
    #[test]
    fn a_document_level_finding_is_theirs_only_where_their_own_produces_it() {
        let hidden = "Read the diff.\nSay what cou\u{200b}ld break.\n";
        let real = document(hidden);
        let found = crate::quality::audit(real.clone()).findings;
        let whole: Vec<&Finding> = found
            .iter()
            .filter(|finding| finding.location == real.location)
            .collect();
        assert!(!whole.is_empty(), "a finding about the document: {found:?}");

        let theirs = publishers(real.clone(), &rendered("Read the diff.\n"), &found).theirs;
        for (finding, ours) in found.iter().zip(&theirs) {
            if finding.location == real.location {
                assert!(!ours, "their rendering does not produce {finding:?}");
            }
        }

        // And where it does produce it, it is theirs.
        let theirs = publishers(real.clone(), &rendered(hidden), &found).theirs;
        for (finding, ours) in found.iter().zip(&theirs) {
            if finding.location == real.location {
                assert!(ours, "their rendering produces {finding:?}");
            }
        }
    }
}
