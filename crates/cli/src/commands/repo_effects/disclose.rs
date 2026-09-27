//! The block a person reads, and the seal taken as they read it.
//!
//! Its own file because it is one concept with one edge: everything here
//! turns an offer into what is on the screen, and hands back exactly what
//! was shown. The consent that follows is next door and reads nothing
//! else. What a declaration means for THIS repository — where a path
//! lands, who shares it, which companions are here — is core's answer, and
//! this only prints it, through the `ui` seam that escapes it.

use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::repo_effects::{DeclaredEffects, Disclosure};

use crate::ui::{self, Span, Status, Style};

/// The block, in the order a reader needs it: what changes, what is
/// written, which packages take part, whatever the package itself wants
/// read, and how to undo it.
///
/// Every line of it is either the package's own words or a fact kendex
/// knows about this machine. Nothing here explains what a declaration
/// MEANS: that is the package's contract, and kendex is not a party to it.
///
/// On the human channel, with the question it belongs to. This is not
/// output a caller composes with — it is the context for `[y/N]`, and the
/// prompt writes to stderr. Sent to stdout, `kendex add ... > log` asks
/// the question with the reasons for it in the file, which is a consent
/// prompt with nothing to consent to.
pub fn disclose(
    env: &Env,
    scope: &Scope,
    effects: &[DeclaredEffects],
) -> Result<Vec<Disclosure>, Box<dyn std::error::Error>> {
    let offers = kendex_core::repo_effects::offers_for(env, scope, effects)?;
    for withheld in &offers.withheld {
        ui::report::notice(&format!(
            "{}: not disclosed — {}",
            withheld.name, withheld.reason
        ));
    }
    for disclosure in &offers.shown {
        print_disclosure(disclosure);
    }
    Ok(offers.shown)
}

/// One package's block, for a surface that already holds the disclosure.
pub fn print_disclosure(disclosure: &Disclosure) {
    ui::report::print(Status::Notice, |style| disclosure_lines(style, disclosure));
}

fn disclosure_lines(style: &Style, disclosure: &Disclosure) -> Vec<String> {
    let mut lines = style.report_callout(
        &format!(
            "{} changes how this repository works, beyond the files above:",
            disclosure.name
        ),
        &disclosure.summary,
    );
    if !disclosure.writes.is_empty() {
        lines.push(String::new());
        lines.extend(style.report_row(Status::Notice, &[Span::Prose("writes")], "  "));
        for written in &disclosure.writes {
            let mark = match written.shared {
                true => "  (shared)",
                false => "",
            };
            lines.extend(
                style.report_detail(&[Span::Command(&written.path), Span::Prose(mark)], "    "),
            );
        }
        if disclosure.writes.iter().any(|written| written.shared) {
            lines.push(String::new());
            lines.extend(style.report_detail(
                &[Span::Prose(
                    "the paths marked shared are the repository's, not this",
                )],
                "  ",
            ));
            lines.extend(style.report_detail(
                &[Span::Prose(
                    "checkout's: every work tree of it sees those files",
                )],
                "  ",
            ));
        }
    }
    if !disclosure.companions.is_empty() {
        lines.push(String::new());
        lines.extend(style.report_row(Status::Notice, &[Span::Prose("companion packages")], "  "));
        for companion in &disclosure.companions {
            let state = match companion.installed {
                true => "installed",
                false => "not installed",
            };
            lines.extend(style.report_detail(
                &[Span::Prose(&format!("{} ({state})", companion.name))],
                "    ",
            ));
        }
    }
    for note in &disclosure.notes {
        lines.push(String::new());
        lines.extend(style.report_detail(&[Span::Prose(note)], "  "));
    }
    lines.push(String::new());
    let undo = disclosure
        .undo
        .as_deref()
        .unwrap_or("the package declares no way to undo it");
    // Core composes the quoted invocation when an uninstaller exists;
    // a package's removal note, or the absent-undo notice, is prose.
    let undo = match disclosure.declared.effects.uninstaller {
        Some(_) => Span::Command(undo),
        None => Span::Prose(undo),
    };
    lines.extend(style.report_detail(&[Span::Prose("to undo: "), undo], "  "));
    lines
}

#[cfg(test)]
mod tests;
