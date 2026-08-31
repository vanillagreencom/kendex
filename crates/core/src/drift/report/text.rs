//! What a folded line may say, and how much of it.
//!
//! A report line is composed here from two kinds of words: kendex's own,
//! over sets this crate bounds, and words from outside that nothing bounds
//! until this module does. Telling them apart is the whole job — the same
//! cut that keeps an error's 4 KB out of an agent's context spelled a
//! `commit hooks` line's second file half way and told a reader to fix
//! files it then declined to name.

use super::*;

/// Where a folded line's words came from, which is what decides the
/// bounding they need. Every caller of [`fold`] says which it is holding,
/// because the two need different treatment and neither reading is safe to
/// guess.
pub enum Text {
    /// Kendex's own sentence, over a set this code bounds — a scope root, a
    /// name this crate validated. Scrubbed and redacted, never cut: the
    /// whole point of such a line is to name things a person then acts on,
    /// so half of one is not a shorter report but a wrong one. What bounds
    /// it is [`render_plain`]'s whole-report budget, which drops a line
    /// entire rather than leaving part of a path behind.
    Own(String),
    /// A FRAGMENT from outside — a name off a source, the tail of an
    /// error — composed into a sentence of kendex's own. Nothing outside
    /// bounds how much of it there may be, so [`shown`] does, and a cut
    /// costs the end of a fragment the line does not turn on.
    Foreign(String),
    /// A WHOLE line another program wrote, relayed rather than described.
    ///
    /// The case the two above could not hold. It is foreign, so it needs
    /// the same scrubbing and a bound; and it is a sentence rather than a
    /// fragment, so cutting it is never right — the growth-guards verdict
    /// carries its remedy at the end, and the fragment bound took the
    /// remedy off every line long enough to need one. So this bounds by
    /// SUBSTITUTION: past [`RELAYED_CHARS`] the reader gets kendex's own
    /// sentence saying so and naming who to ask, never half of somebody
    /// else's.
    ///
    /// `producer` is kendex's own noun phrase for whoever wrote the line,
    /// and says how to read it in full; `line` is their bytes.
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
            Text::Foreign(text) => shown(&text),
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

/// How much of a foreign string the report will spell. Nothing outside
/// bounds it, so this does — and raising it is not the answer to a line
/// that came out short, because the next path is longer again.
pub(super) const FOREIGN_CHARS: usize = 300;

/// Foreign text on its way into the report: control characters become
/// spaces, credentials become fingerprints, length is bounded.
///
/// A fragment bounder, not a line one. It goes around each piece that came
/// from outside — an error's message, a name off a source — and the line is
/// composed around the results. Wrapped around a whole composed line it
/// cuts kendex's own prose instead, which is what left a `commit hooks`
/// line naming files to delete with the second one spelled half way.
pub(super) fn shown(raw: &str) -> String {
    printable(&raw.chars().take(FOREIGN_CHARS).collect::<String>())
}

/// How long a relayed line may be before the report declines to carry it.
///
/// Generous against every verdict any delegated script actually writes —
/// the longest growth-guards has runs to about 400 characters — because
/// the point is not to trim, it is to have an answer for a program that
/// answers with a megabyte. A report line is one line, and `--json`
/// carries whatever this returns.
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
