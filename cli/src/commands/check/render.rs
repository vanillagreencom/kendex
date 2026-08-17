//! Rendering the drift report: the human and quiet text, plus the
//! credential-, control- and length-scrubbing every displayed string passes
//! through on its way there.

use super::{AvailableItem, CATALOG_KINDS, CheckReport, Item, ScopeReport, SourceProblem};
use std::collections::HashSet;

/// How much free text (a source string, a parse failure, a name) may reach an
/// agent's context on one report line.
const DISPLAY_LIMIT: usize = 120;

/// [`DISPLAY_LIMIT`] for a diagnostic that IS the remedy — a refusal names the
/// cache entry and the next step, and a cache root is a full path, so the
/// prose bound cut the instruction off. Still bounded by construction, just
/// wide enough to carry a sentence with a path in it.
const REASON_LIMIT: usize = DISPLAY_LIMIT * 4;

/// Remove credentials from a source string. Applied at report construction,
/// so every consumer — human report, quiet hook line, `--json` on stdout, CI
/// logs quoting either — sees credential-free strings.
///
/// One redaction, shared with every source diagnostic vstack prints: a token
/// shape that one implementation handled and another did not is a token in a
/// CI log. Which half of a userinfo is a secret is a question about the
/// transport's grammar, and [`crate::refresh_sources::remote_source_display`]
/// is where that grammar lives.
pub(super) fn scrub_source_credentials(text: &str) -> String {
    crate::refresh_sources::remote_source_display(text)
}

/// Characters a shell passes through untouched, so an argument built only
/// from them needs no quoting at all.
fn is_shell_safe(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '/' | '@' | ':' | '=' | '-')
}

/// A source rendered INSIDE a copy-paste command: credential- and
/// control-scrubbed like prose, but never truncated — an elided argument is
/// a command that cannot work — and single-quoted whenever it holds anything
/// a shell would interpret, so the pasted command runs on the literal string
/// rather than on whatever `$`, backtick, or quote it happened to contain.
pub(crate) fn command_arg(text: &str) -> String {
    let scrubbed: String = scrub_source_credentials(text)
        .chars()
        .map(|c| if c.is_control() { '?' } else { c })
        .collect();
    if !scrubbed.is_empty() && scrubbed.chars().all(is_shell_safe) {
        return scrubbed;
    }
    // POSIX single-quoting: nothing inside `'…'` is special, and the one
    // character that cannot appear there is spliced back in as `'\''`.
    format!("'{}'", scrubbed.replace('\'', r"'\''"))
}

/// Defensive rendering of text that did not pass through
/// `is_safe_item_name` (source strings, parse failures, agent-declared
/// skill references): credentials embedded in a URL are removed, control
/// characters become `?` so nothing can start a new line or drive a
/// terminal, and anything long is truncated — an item is never classified on
/// its length, only shortened when shown.
pub(crate) fn display_text(text: &str) -> String {
    display_bounded(text, DISPLAY_LIMIT)
}

/// [`display_text`] for a cause-and-remedy sentence; see [`REASON_LIMIT`].
pub(crate) fn display_reason(text: &str) -> String {
    display_bounded(text, REASON_LIMIT)
}

fn display_bounded(text: &str, limit: usize) -> String {
    let scrubbed: String = scrub_source_credentials(text)
        .chars()
        .map(|c| if c.is_control() { '?' } else { c })
        .collect();
    if scrubbed.chars().count() <= limit {
        return scrubbed;
    }
    let kept: String = scrubbed.chars().take(limit).collect();
    format!("{kept}…")
}

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

/// What a block of the report is for, and therefore the order in which it
/// claims lines from the quiet budget: what an agent has to act on comes
/// before what it may optionally add. Within a priority, blocks claim in
/// report order — so the same report always omits the same lines, and drift
/// never appears or vanishes because a suggestion list grew.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BlockPriority {
    Drift,
    Suggestion,
}

/// Concatenate `blocks` in report order, keeping the whole rendering inside
/// BOTH budgets and closing with one line naming everything left out.
///
/// Lines alone do not bound a report: names are unrestricted in length and a
/// copy-paste command argument is deliberately never truncated, so a report
/// well inside the line budget can still be arbitrarily large. A line that
/// does not fit what the byte budget has left ends its block, exactly as a
/// spent line budget does.
///
/// Under both budgets this is a plain concatenation — byte for byte what the
/// report was before there was a budget at all.
fn spend_report_budget(
    blocks: &[(BlockPriority, String)],
    line_budget: usize,
    byte_budget: usize,
) -> String {
    let lines = |text: &str| text.split_inclusive('\n').count();
    let total: usize = blocks.iter().map(|(_, text)| lines(text)).sum();
    let total_bytes: usize = blocks.iter().map(|(_, text)| text.len()).sum();
    if total <= line_budget && total_bytes <= byte_budget {
        return blocks.iter().map(|(_, text)| text.as_str()).collect();
    }

    let mut kept = vec![0usize; blocks.len()];
    let mut lines_left = line_budget;
    let mut bytes_left = byte_budget;
    for priority in [BlockPriority::Drift, BlockPriority::Suggestion] {
        for (index, (block_priority, text)) in blocks.iter().enumerate() {
            if *block_priority != priority {
                continue;
            }
            for line in text.split_inclusive('\n') {
                if lines_left == 0 || line.len() > bytes_left {
                    break;
                }
                lines_left -= 1;
                bytes_left -= line.len();
                kept[index] += 1;
            }
        }
    }

    let mut out = String::new();
    for (index, (_, text)) in blocks.iter().enumerate() {
        out.extend(text.split_inclusive('\n').take(kept[index]));
    }
    let omitted = total - kept.iter().sum::<usize>();
    if omitted > 0 {
        if !out.ends_with('\n') {
            out.push('\n');
        }
        out.push_str(&format!(
            "  … and {omitted} more report line(s) (run `vstack check` for the full report)\n"
        ));
    }
    out
}

pub(super) fn humanize_age(secs: u64) -> String {
    match secs {
        0..=119 => format!("{secs}s"),
        120..=7199 => format!("{}m", secs / 60),
        _ => format!("{}h", secs / 3600),
    }
}

/// How many lines a single section may spend in the quiet report. The quiet
/// report is relayed verbatim into an agent's context by both session
/// adapters, so its size is bounded BY CONSTRUCTION rather than by how large
/// an inventory happens to be. Headers keep the true counts; the full listing
/// is one `vstack check` away.
const QUIET_SECTION_LIMIT: usize = 10;

/// How many lines the WHOLE quiet report may spend, before its closing
/// summary. [`QUIET_SECTION_LIMIT`] bounds each section; nothing bounded their
/// sum, and a project with dozens of unreachable sources renders a header and
/// a detail list per source — hundreds of lines into an agent's context
/// through both session adapters. Wide enough for several fully capped
/// sections across both scopes, and a hard ceiling past that.
const QUIET_REPORT_LINE_BUDGET: usize = 60;

/// How many BYTES the whole quiet report may spend, before its closing
/// summary. Counting lines bounds how many entries an agent sees, not how much
/// of its context they take: one displayed value is capped at
/// [`REASON_LIMIT`], a copy-paste command argument at nothing at all, and a
/// budget that counts only lines waves either through. Wide enough that no
/// real report is trimmed on this axis — [`QUIET_REPORT_LINE_BUDGET`] lines of
/// ordinary width sit far inside it — and a hard ceiling past that.
const QUIET_REPORT_BYTE_BUDGET: usize = 8 * 1024;

/// How many of `total` entries this mode renders.
fn shown_count(quiet: bool, total: usize) -> usize {
    if quiet {
        total.min(QUIET_SECTION_LIMIT)
    } else {
        total
    }
}

/// The `… and M more` line for whatever a capped section left out.
fn overflow_line(out: &mut String, indent: &str, shown: usize, total: usize) {
    if total > shown {
        out.push_str(&format!(
            "{indent}… and {} more (run `vstack check` for the full report)\n",
            total - shown
        ));
    }
}

/// One drift section: a header line and one `glyph name (kind)` line per
/// item, with the item's own detail when the header cannot carry it. Capped
/// in quiet mode; the header's count is always the true total.
///
/// `render_detail` is how wide a detail may run: [`display_text`] for a label
/// beside a remedy the header already gave, [`display_reason`] where the
/// detail IS the remedy — a file to repair and the failure that named it.
fn section(
    out: &mut String,
    header: &str,
    glyph: char,
    items: &[Item],
    quiet: bool,
    render_detail: fn(&str) -> String,
) {
    if items.is_empty() {
        return;
    }
    out.push_str(&format!("\n  {} {header}:\n", items.len()));
    let shown = shown_count(quiet, items.len());
    for item in &items[..shown] {
        let detail = item
            .detail
            .as_deref()
            .map(|detail| format!(" — {}", render_detail(detail)))
            .unwrap_or_default();
        out.push_str(&format!(
            "    {glyph} {} ({}){detail}\n",
            display_text(&item.name),
            item.kind
        ));
    }
    overflow_line(out, "    ", shown, items.len());
}

/// The `? <name>` list a source problem attaches to its header. Every name is
/// scrubbed here rather than at the caller, so the module's guarantee — nothing
/// reaches the report unscrubbed — holds at the point of rendering. Capped in
/// quiet mode; the header above it already carries the true count.
fn render_entry_names(out: &mut String, entries: &[String], quiet: bool) {
    use std::fmt::Write as _;
    let shown = shown_count(quiet, entries.len());
    for name in &entries[..shown] {
        let _ = writeln!(out, "    ? {}", display_text(name));
    }
    overflow_line(out, "    ", shown, entries.len());
}

/// The scope flag every remediation command in a section carries. A section
/// belongs to exactly one scope while `add` and `remove` default to PROJECT
/// scope, so a global section printing a bare `vstack remove <name>` either
/// clears nothing or — when a project install shares the name — removes the
/// wrong one. `vstack refresh` deliberately never takes it: unflagged, it
/// reinstalls at every scope an item is locked at.
fn scope_flag(scope: &str) -> &'static str {
    match scope {
        "global" => " -g",
        _ => "",
    }
}

/// One scope's rendering, whole — drift followed by the suggestions that
/// close it, exactly as the report prints them.
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
    render_available(suggestions, report, quiet);
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
            let _ = writeln!(out, "  ✓ {} ({})", display_text(&item.name), item.kind);
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
    // width of a remedy rather than of a label.
    section(
        out,
        "installed, but the install could not be verified — repair the file named below",
        '?',
        &report.unverifiable,
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

    for issue in &report.source_issues {
        let source = display_text(&issue.source);
        match &issue.problem {
            SourceProblem::Unresolvable { entries, reason } => {
                let _ = writeln!(
                    out,
                    "\n  source {source} is unreachable — {} — {} item(s) cannot be verified; run `vstack add{g} {}` to restore it, or `vstack remove{g} <name>` if it is gone for good:",
                    display_reason(reason),
                    entries.len(),
                    command_arg(&issue.source),
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
                    let _ = writeln!(out, "    ✗ {}", display_text(reason));
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
                let names: Vec<&str> = offered
                    .iter()
                    .filter(|a| a.source == source)
                    .map(|a| a.name.as_str())
                    .collect();
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
                // happens to pick.
                let _ = writeln!(
                    out,
                    "    + {} (`vstack add{g} {} {flag} <name>`): {}{overflow}",
                    kind.label_plural(),
                    command_arg(source),
                    listed.join(", ")
                );
            }
        }
    }
}

#[cfg(test)]
mod tests;
