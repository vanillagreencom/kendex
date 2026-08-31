//! What a folded line may say, and how much of it.
//!
//! Every line here is bounded, and the whole job is deciding HOW. A line
//! kendex composed over a set this crate bounds is already the right
//! length. A line carrying somebody else's whole sentence is not, and
//! cannot be trimmed to fit — so past its bound it is replaced. Getting
//! that wrong both ways is what this module remembers: the fragment cut
//! that keeps an error's 4 KB out of an agent's context spelled a
//! `commit hooks` line's second file half way and told a reader to fix
//! files it then declined to name, and the same cut later took the remedy
//! off the end of a relayed verdict.
//!
//! [`shown`] still cuts fragments, and `scope` composes lines around it.
//! What no longer exists is a way to hand a WHOLE line to that cut.

use super::*;

/// How a folded line has to be bounded. Every caller of [`fold`] says
/// which it is holding, because the two need different treatment and
/// neither reading is safe to guess.
pub enum Text {
    /// Kendex's own sentence, over a set this code bounds — a scope root, a
    /// name this crate validated. Scrubbed and redacted, never cut: the
    /// whole point of such a line is to name things a person then acts on,
    /// so half of one is not a shorter report but a wrong one. What bounds
    /// it is [`render_plain`]'s whole-report budget, which drops a line
    /// entire rather than leaving part of a path behind.
    Own(String),
    /// A whole sentence carrying bytes from outside — a delegated script's
    /// verdict, an io error's cause — which is never cut.
    ///
    /// Not "foreign words", which [`shown`] already bounds a fragment of
    /// at a time wherever a line is composed AROUND one. This is the case
    /// that has no such line to be composed around: what would be cut is
    /// the sentence itself, and what sits at a sentence's end is the part
    /// worth having — the growth-guards verdict carries its remedy there,
    /// and an io error carries its cause. So this bounds by SUBSTITUTION:
    /// past [`RELAYED_CHARS`] the reader gets kendex's own sentence saying
    /// so, never half of one that reads finished.
    ///
    /// `line` is what is shown, framing and all, so a caller that needs
    /// the reader oriented composes that framing into it. `producer` names
    /// who to go and ask, which is not always who wrote the bytes: a line
    /// reporting that the hooks directory would not answer names the hooks
    /// directory. It is shown in the one case `line` is not.
    Relayed { producer: String, line: String },
}

/// Fold in a verdict this module will not take itself. [`check`] launches
/// no subprocess: it runs at every session start. The commit-hook verdict
/// costs one and belongs to the package owning the shims, so the command
/// layer takes it and hands the answer here. The section lands last and the
/// status rises to meet it: a check reporting "all clear" while nothing
/// gates commits is worse than no check.
pub fn fold(report: &mut CheckReport, title: &str, class: Class, text: Text) {
    let line = Line {
        class,
        text: match text {
            Text::Own(text) => printable(&text),
            Text::Relayed { producer, line } => relayed(&producer, &line),
        },
        remedy: None,
    };
    match report
        .sections
        .iter_mut()
        .find(|section| section.title == title)
    {
        Some(section) => section.lines.push(line),
        None => report.sections.push(Section {
            title: title.to_owned(),
            lines: vec![line],
        }),
    }
    let raised = match class {
        Class::Drift | Class::Unevaluated => CheckStatus::Drift,
        Class::Unknown => CheckStatus::Unknown,
    };
    report.status = report.status.max(raised);
}

/// How much of a foreign FRAGMENT the report will spell. Nothing outside
/// bounds it, so this does — and raising it is not the answer to a line
/// that came out short, because the next path is longer again.
pub(super) const FOREIGN_CHARS: usize = 300;

/// Foreign text on its way into the report: control characters become
/// spaces, credentials become fingerprints, length is bounded.
///
/// A fragment bounder, not a line one. It goes around a piece that came
/// from outside — an error's message, a name off a source — and the line is
/// composed around the result. Wrapped around a whole composed line it
/// cuts kendex's own prose instead, which is what left a `commit hooks`
/// line naming files to delete with the second one spelled half way.
pub(super) fn shown(raw: &str) -> String {
    printable(&raw.chars().take(FOREIGN_CHARS).collect::<String>())
}

/// How long a relayed line may be before the report declines to carry it.
///
/// Generous, because the point is not to trim: a verdict a delegated
/// script actually writes should arrive whole, and this exists to have an
/// answer for a program that answers with a megabyte. A report line is one
/// line, and `--json` carries whatever this returns.
pub(super) const RELAYED_CHARS: usize = 2000;

/// A whole relayed line, scrubbed and never cut.
///
/// Past the bound the line is REPLACED, not trimmed: a verdict stopping
/// mid-remedy reads as a verdict, and the reader acts on the half they were
/// given. What they get instead says the length, names who to ask, and
/// leaves the line's class and the run's exit code exactly as they were.
fn relayed(producer: &str, line: &str) -> String {
    let length = line.chars().count();
    match length > RELAYED_CHARS {
        true => printable(&format!(
            "{producer} answered with {length} characters, too long to show here"
        )),
        false => printable(line),
    }
}

/// The same scrubbing with no cut: control characters become spaces so
/// nothing a path carries can forge a second report line, and credentials
/// become fingerprints. For text whose length this crate already bounds.
fn printable(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    crate::quality::redact(cleaned.trim())
}
