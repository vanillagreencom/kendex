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
                    // Deliberately silent about the CAUSE — the reason
                    // printed just above already carries it, and the two
                    // absent-with-no-remedy states have different ones: no
                    // identity recorded at all, and an identity that names a
                    // repository where the lock recorded a directory inside
                    // it.
                    // The second half is deliberately NOT a backticked
                    // command: there is no argument to give it, and a
                    // `vstack add <source>` shape here reads as something to
                    // paste in a report whose whole contract is that what it
                    // prints can be.
                    None => format!(
                        "nothing recorded can restore it — run `vstack remove{g} <name>`, or re-add these items from a source you choose"
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
            SourceProblem::Unverifiable {
                entries,
                reason,
                restore,
            } => {
                // The refusal already names the entry, the cause and the
                // next step, and is relayed verbatim rather than reworded. No
                // second remedy is invented on top of it — most refused
                // sources refuse again when re-added, which sends the reader
                // in a circle — EXCEPT where re-adding provably clears the
                // state, which the refusal wording does not say and the reader
                // has no other way to discover.
                let remedy = match restore {
                    Some(arg) => format!(
                        "; run `vstack add{g} {}` to install these from its remote instead",
                        command_arg(arg)
                    ),
                    None => String::new(),
                };
                let _ = writeln!(
                    out,
                    "\n  source {source} — {} item(s) cannot be verified: {}{remedy}",
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
