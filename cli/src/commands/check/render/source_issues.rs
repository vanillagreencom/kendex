//! Rendering the per-source problems a scope reports: what went wrong with
//! each recorded source, and the remedy for it.
//!
//! Every command printed here has to WORK when the reader pastes it. That is
//! why the `vstack add` argument travels on the report rather than being
//! rebuilt from the source string: a path into vstack's own cache names a
//! clone vstack mints, not a source a user keeps, so re-adding the path sent
//! the reader round a loop this report had prescribed.

use super::*;

pub(super) fn render_source_issues(out: &mut String, report: &ScopeReport, quiet: bool) {
    use std::fmt::Write as _;

    let g = scope_flag(report.scope);
    for issue in &report.source_issues {
        let source = display_text(&issue.source);
        match &issue.problem {
            SourceProblem::Unresolvable {
                entries,
                reason,
                restore,
            } => {
                // Only an `add` that can actually succeed is offered. Re-adding
                // a vanished path into vstack's own cache cannot: there is
                // nothing there to read, and printing it sent the user round a
                // loop the report itself had prescribed.
                let remedy = match restore {
                    Some(arg) => format!(
                        "run `vstack add{g} {}` to restore it, or `vstack remove{g} <name>` if it is gone for good",
                        command_arg(arg)
                    ),
                    None => format!(
                        "no source is recorded to restore it from — run `vstack remove{g} <name>`, or `vstack add{g} <source>` to install these from one"
                    ),
                };
                let _ = writeln!(
                    out,
                    "\n  source {source} is unreachable — {} — {} item(s) cannot be verified; {remedy}:",
                    display_reason(reason),
                    entries.len(),
                );
                render_entry_names(out, entries, quiet);
            }
            SourceProblem::Unreadable { entries, reasons } => {
                let _ = writeln!(
                    out,
                    "\n  source {source} cannot be inventoried — {} item(s) cannot be verified; fix the source layout, refresh cannot:",
                    entries.len()
                );
                let shown = shown_count(quiet, reasons.len());
                for reason in &reasons[..shown] {
                    // A layout reason is a full path plus what was found there,
                    // and the prose bound cut it off after the path — leaving a
                    // line that named a root without saying what was wrong with
                    // it. This IS the remedy, so it gets the reason bound.
                    let _ = writeln!(out, "    ✗ {}", display_reason(reason));
                }
                overflow_line(out, "    ", shown, reasons.len());
                render_entry_names(out, entries, quiet);
            }
            // The refusal already names the entry, the cause and the next
            // step. It is relayed rather than reworded, and no `vstack add` is
            // prescribed on top of it: a source vstack REFUSED refuses again
            // when re-added, which sends the user in a circle.
            SourceProblem::Unverifiable { entries, reason } => {
                let _ = writeln!(
                    out,
                    "\n  source {source} — {} item(s) cannot be verified: {}",
                    entries.len(),
                    display_reason(reason),
                );
                render_entry_names(out, entries, quiet);
            }
            SourceProblem::Discovery { failures } => {
                let _ = writeln!(
                    out,
                    "\n  source {source} has {} asset(s) that could not be read — fix them upstream before trusting refresh:",
                    failures.len()
                );
                let shown = shown_count(quiet, failures.len());
                for failure in &failures[..shown] {
                    let _ = writeln!(out, "    ✗ {}", display_text(failure));
                }
                overflow_line(out, "    ", shown, failures.len());
            }
        }
    }
}
