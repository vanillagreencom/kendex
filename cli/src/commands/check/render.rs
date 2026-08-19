//! Rendering the drift report: the human and quiet text, assembled out of the
//! credential-, control- and length-scrubbing helpers in [`crate::display`],
//! which every displayed string in the CLI passes through.

use super::{AvailableItem, CATALOG_KINDS, CheckReport, GitHooksState, ScopeReport, SourceProblem};
use budget::{
    BlockPriority, QUIET_REPORT_BYTE_BUDGET, QUIET_REPORT_LINE_BUDGET, overflow_line,
    render_entry_names, section, shown_count, spend_report_budget,
};

mod budget;
mod source_issues;
use source_issues::render_source_issues;

use std::collections::HashSet;

pub(crate) use crate::display::{
    command_arg, display_reason, display_text, scrub_prose, scrub_source_credentials,
};

/// Human report. `quiet` drops headers and per-item listings and prints
/// nothing at all when no scope has drift; suggestions and cache warnings
/// then ride along only with real drift, so a clean session stays silent.
///
/// The quiet rendering is assembled as budgetable blocks and then trimmed to
/// [`QUIET_REPORT_LINE_BUDGET`]; the interactive one is complete and never
/// trimmed.
pub(super) fn render_report(report: &CheckReport, quiet: bool) -> String {
    if quiet && !report.drift {
        return String::new();
    }
    let mut blocks: Vec<(BlockPriority, String)> = Vec::new();
    for scope in &report.scopes {
        let mut drift = String::new();
        let mut suggestions = String::new();
        render_scope_parts(&mut drift, &mut suggestions, scope, quiet);
        blocks.push((BlockPriority::Drift, drift));
        blocks.push((BlockPriority::Suggestion, suggestions));
    }

    let mut caches = String::new();
    if let Some(error) = &report.background_refresh_error {
        caches.push_str(&format!(
            "\n  source caches could not be refreshed in the background ({error}); run `vstack refresh` to update them\n"
        ));
    }
    if !report.cache_refresh_failures.is_empty() {
        caches.push('\n');
        let shown = shown_count(quiet, report.cache_refresh_failures.len());
        for failure in &report.cache_refresh_failures[..shown] {
            caches.push_str(&format!(
                "  source cache {} is not up to date — {}; results may be stale — run `vstack refresh` to retry it now\n",
                display_text(&failure.source),
                failure.reason
            ));
        }
        overflow_line(
            &mut caches,
            "  ",
            shown,
            report.cache_refresh_failures.len(),
        );
    }
    // A cache that cannot refresh is a state to act on, not an offer.
    blocks.push((BlockPriority::Drift, caches));

    if !quiet {
        return blocks.into_iter().map(|(_, text)| text).collect();
    }
    spend_report_budget(&blocks, QUIET_REPORT_LINE_BUDGET, QUIET_REPORT_BYTE_BUDGET)
}

pub(super) fn humanize_age(secs: u64) -> String {
    match secs {
        0..=119 => format!("{secs}s"),
        120..=7199 => format!("{}m", secs / 60),
        _ => format!("{}h", secs / 3600),
    }
}

/// The scope flag every remediation command in a section carries. A section
/// belongs to exactly one scope while `add` and `remove` default to PROJECT
/// scope, so a global section printing a bare `vstack remove <name>` either
/// clears nothing or — when a project install shares the name — removes the
/// wrong one. `vstack refresh` deliberately never takes it: unflagged, it
/// reinstalls at every scope an item is locked at.
pub(super) fn scope_flag(scope: &str) -> &'static str {
    crate::refresh_sources::scope_flag(scope == "global")
}

/// One scope's rendering, whole — drift followed by the suggestions that
/// close it, exactly as the report prints them.
#[cfg(test)]
pub(super) fn render_scope(out: &mut String, report: &ScopeReport, quiet: bool) {
    let mut suggestions = String::new();
    render_scope_parts(out, &mut suggestions, report, quiet);
    out.push_str(&suggestions);
}

/// [`render_scope`] with its two halves kept apart, so the quiet budget can
/// tell what an agent must act on from what it is merely offered.
fn render_scope_parts(
    drift: &mut String,
    suggestions: &mut String,
    report: &ScopeReport,
    quiet: bool,
) {
    if quiet && !report.has_drift() {
        return;
    }
    render_scope_drift(drift, report, quiet);
    render_busy_sources(suggestions, report, quiet);
    render_available(suggestions, report, quiet);
}

/// Sources that were being refreshed while the check ran.
///
/// It rides in the non-drift block on purpose. A busy cache is not something
/// to act on, so it must never claim budget from something that is — and it
/// must never be the reason a clean quiet report speaks at all, because a
/// background refresh finishing normally is not news to put in an agent's
/// context at every session start. When the report is speaking anyway it says
/// this too: it is the only thing that explains why entries the user installed
/// appear in no list this run.
fn render_busy_sources(out: &mut String, report: &ScopeReport, quiet: bool) {
    use std::fmt::Write as _;

    for busy in &report.busy_sources {
        let _ = writeln!(
            out,
            "\n  source {} is being refreshed by another vstack process — {} item(s) not checked this run: {}",
            display_text(&busy.source),
            busy.entries.len(),
            display_reason(&busy.reason),
        );
        render_entry_names(out, &busy.entries, quiet);
    }
}

fn render_scope_drift(out: &mut String, report: &ScopeReport, quiet: bool) {
    use std::fmt::Write as _;

    let g = scope_flag(report.scope);

    if quiet {
        let _ = writeln!(out, "vstack drift — {} scope:", report.scope);
    } else {
        let _ = writeln!(
            out,
            "\n{} scope: {} item(s)",
            report.scope, report.installed
        );
        for item in &report.current {
            let enforcement = item
                .enforcement
                .as_deref()
                .map(|summary| format!(" [{}]", display_text(summary)))
                .unwrap_or_default();
            let _ = writeln!(
                out,
                "  ✓ {} ({}){enforcement}",
                display_text(&item.name),
                item.kind
            );
        }
    }

    // The git-shim verdict rides as one line either way: an armed one in the
    // ✓ listing, anything else as the drift it is — the detail is the
    // checker's own line and already carries the remedy.
    if let Some(hooks) = &report.git_hooks {
        match hooks.state {
            GitHooksState::Armed => {
                if !quiet {
                    let _ = writeln!(out, "  ✓ {}", display_reason(&hooks.detail));
                }
            }
            GitHooksState::Unarmed => {
                let _ = writeln!(out, "\n  ✗ {}", display_reason(&hooks.detail));
            }
            GitHooksState::Undetermined => {
                let _ = writeln!(out, "\n  ? {}", display_reason(&hooks.detail));
            }
        }
    }

    section(
        out,
        "outdated — run `vstack refresh` to update",
        '!',
        &report.outdated,
        quiet,
        display_text,
    );
    section(
        out,
        &format!("no longer in source — run `vstack remove{g} <name>`"),
        '✗',
        &report.removed,
        quiet,
        display_text,
    );
    section(
        out,
        &format!("installed on disk but missing from lock — run `vstack add{g}` to recover"),
        '?',
        &report.orphaned,
        quiet,
        display_text,
    );
    section(
        out,
        &format!(
            "in lock but missing from disk — run `vstack add{g}` to clean up, or `vstack remove{g} <name>`"
        ),
        '✗',
        &report.phantom,
        quiet,
        display_text,
    );
    // Deliberately its own section: reinstalling repairs nothing here, and
    // the detail names the file whose repair does — so the detail is given the
    // width of a remedy rather than of a label. The header is the remedy and
    // claims nothing about the artifacts, because a row here can carry both
    // faults at once: a missing artifact AND the file whose repair the
    // reinstall for it waits on.
    section(
        out,
        "repair the file named below — no reinstall can clear these",
        '?',
        &report.unverifiable,
        quiet,
        display_reason,
    );
    // Its own section for the same reason and a different remedy: every
    // artifact is present and readable, and the harness is switched off. A
    // reinstall rewrites files that are already correct; the detail names the
    // setting that has to change, so it too is given a remedy's width.
    section(
        out,
        "installed, but the harness will not run it — change the setting named below",
        '○',
        &report.disabled,
        quiet,
        display_reason,
    );

    if !report.missing_skill_refs.is_empty() {
        let agents: HashSet<&str> = report
            .missing_skill_refs
            .iter()
            .map(|r| r.agent.as_str())
            .collect();
        let _ = writeln!(
            out,
            "\n  {} agent(s) reference uninstalled skill(s):",
            agents.len()
        );
        let shown = shown_count(quiet, report.missing_skill_refs.len());
        for r in &report.missing_skill_refs[..shown] {
            let _ = writeln!(
                out,
                "    ✗ agent {} references skill {} but it's not installed; run `vstack add{g} --skill {} .` or `vstack add{g}` to auto-install dependent skills.",
                display_text(&r.agent),
                display_text(&r.skill),
                command_arg(&r.skill),
            );
        }
        overflow_line(out, "    ", shown, report.missing_skill_refs.len());
    }

    render_source_issues(out, report, quiet);

    if !report.invalid_names.is_empty() {
        let _ = writeln!(
            out,
            "\n  {} name(s) rejected (unsafe to render or resolve) — inspect the lock file and installed agents by hand:",
            report.invalid_names.len()
        );
        let shown = shown_count(quiet, report.invalid_names.len());
        for item in &report.invalid_names[..shown] {
            let _ = writeln!(out, "    ✗ <invalid name> ({})", item.kind);
        }
        overflow_line(out, "    ", shown, report.invalid_names.len());
    }
}

/// The "available in source but not installed" offers — suggestions, never
/// drift, and the first thing the quiet budget gives up.
fn render_available(out: &mut String, report: &ScopeReport, quiet: bool) {
    use std::fmt::Write as _;

    let g = scope_flag(report.scope);
    if !report.available.is_empty() {
        let _ = writeln!(
            out,
            "\n  {} available in source but not installed — suggestions only, ask before adding:",
            report.available.len()
        );
        for kind in CATALOG_KINDS {
            let Some(flag) = kind.add_filter_flag() else {
                continue;
            };
            let offered: Vec<&AvailableItem> =
                report.available.iter().filter(|a| a.kind == kind).collect();
            if offered.is_empty() {
                continue;
            }
            // Group by source: which repo is offering an item is half of
            // deciding whether to add it.
            let mut sources: Vec<&str> = offered.iter().map(|a| a.source.as_str()).collect();
            sources.sort();
            sources.dedup();
            for source in sources {
                let from_source = || offered.iter().filter(|a| a.source == source);
                let names: Vec<&str> = from_source().map(|a| a.name.as_str()).collect();
                // Decided upstream, from the raw string: `source` here is the
                // redacted display, and a redacted spelling names nothing.
                let add_argument = from_source().find_map(|a| a.add_argument.as_deref());
                let shown = shown_count(quiet, names.len());
                let overflow = if names.len() > shown {
                    format!(", … and {} more", names.len() - shown)
                } else {
                    String::new()
                };
                // Every displayed name is bounded, this one included: item
                // name length is deliberately unrestricted, so one long name
                // joined raw is an unbounded line that the line budget counts
                // as one and waves through.
                let listed: Vec<String> = names[..shown].iter().map(|n| display_text(n)).collect();
                // The source is part of the command, not a footnote: with
                // two sources offering the same name, an unqualified `vstack
                // add --skill <name>` installs whichever one resolution
                // happens to pick. Which is why a source that cannot BE an
                // argument is offered without one rather than with a command
                // naming a directory that does not exist — the items really
                // are available, so the line still says so.
                let offer = match add_argument {
                    Some(arg) => format!("`vstack add{g} {} {flag} <name>`", command_arg(arg)),
                    None => format!("available from {}", display_text(source)),
                };
                let _ = writeln!(
                    out,
                    "    + {} ({offer}): {}{overflow}",
                    kind.label_plural(),
                    listed.join(", ")
                );
            }
        }
    }
}

#[cfg(test)]
mod tests;
