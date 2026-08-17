//! How much of a report the quiet rendering may spend, and the section
//! primitives that obey it.
//!
//! The quiet report is relayed verbatim into an agent's context by both
//! session adapters, so its size is bounded BY CONSTRUCTION rather than by how
//! large an inventory happens to be. WHAT the sections say is [`super`]'s.

use crate::commands::check::Item;
use crate::display::display_text;

/// What a block of the report is for, and therefore the order in which it
/// claims lines from the quiet budget: what an agent has to act on comes
/// before what it may optionally add. Within a priority, blocks claim in
/// report order — so the same report always omits the same lines, and drift
/// never appears or vanishes because a suggestion list grew.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum BlockPriority {
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
pub(super) fn spend_report_budget(
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

/// How many lines a single section may spend in the quiet report. The quiet
/// report is relayed verbatim into an agent's context by both session
/// adapters, so its size is bounded BY CONSTRUCTION rather than by how large
/// an inventory happens to be. Headers keep the true counts; the full listing
/// is one `vstack check` away.
pub(super) const QUIET_SECTION_LIMIT: usize = 10;

/// How many lines the WHOLE quiet report may spend, before its closing
/// summary. [`QUIET_SECTION_LIMIT`] bounds each section; nothing bounded their
/// sum, and a project with dozens of unreachable sources renders a header and
/// a detail list per source — hundreds of lines into an agent's context
/// through both session adapters. Wide enough for several fully capped
/// sections across both scopes, and a hard ceiling past that.
pub(super) const QUIET_REPORT_LINE_BUDGET: usize = 60;

/// How many BYTES the whole quiet report may spend, before its closing
/// summary. Counting lines bounds how many entries an agent sees, not how much
/// of its context they take: one displayed value is capped at
/// [`REASON_LIMIT`], a copy-paste command argument at nothing at all, and a
/// budget that counts only lines waves either through. Wide enough that no
/// real report is trimmed on this axis — [`QUIET_REPORT_LINE_BUDGET`] lines of
/// ordinary width sit far inside it — and a hard ceiling past that.
pub(super) const QUIET_REPORT_BYTE_BUDGET: usize = 8 * 1024;

/// How many of `total` entries this mode renders.
pub(super) fn shown_count(quiet: bool, total: usize) -> usize {
    if quiet {
        total.min(QUIET_SECTION_LIMIT)
    } else {
        total
    }
}

/// The `… and M more` line for whatever a capped section left out.
pub(super) fn overflow_line(out: &mut String, indent: &str, shown: usize, total: usize) {
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
pub(super) fn section(
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
pub(super) fn render_entry_names(out: &mut String, entries: &[String], quiet: bool) {
    use std::fmt::Write as _;
    let shown = shown_count(quiet, entries.len());
    for name in &entries[..shown] {
        let _ = writeln!(out, "    ? {}", display_text(name));
    }
    overflow_line(out, "    ", shown, entries.len());
}
