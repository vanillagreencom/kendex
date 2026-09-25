//! Plain-text rendering of a check report, bounded for the session hook
//! and complete for an explicit check.

use super::*;

/// Why a fix will not run where the report was read. Said once, here,
/// because this is the only place it is printed, and it names the
/// condition rather than a place to go instead: which session is free of
/// the hook is not something a report can know.
const NOT_FROM_HERE: &str = " (no --project-path form; the block-worktree-refresh hook refuses this verb inside a linked worktree)";

/// A duration as the shortest honest spelling: "3m", "5h", "2d".
fn age_word(secs: u64) -> String {
    match secs {
        s if s < 120 => "moments".to_owned(),
        s if s < 7200 => format!("{}m", s / 60),
        s if s < 172_800 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86_400),
    }
}

fn next_action(report: &CheckReport) -> Option<String> {
    let mut global = false;
    let mut project = false;
    for remedy in report
        .sections
        .iter()
        .flat_map(|section| &section.lines)
        .filter_map(|line| line.remedy.as_ref())
    {
        if let Remedy::Refresh { global: is_global } = remedy {
            global |= *is_global;
            project |= !*is_global;
        }
    }
    let command =
        |global| match Remedy::render_refresh_action(global, report.project_target.as_ref()) {
            Some(Fix::Here(command)) => Some(format!("{command} --yes")),
            Some(Fix::Elsewhere(_)) | None => None,
        };
    let checkout = match report.project_target {
        Some(ProjectTarget::MainCheckout(_)) => "in that checkout",
        Some(ProjectTarget::Worktree(_)) | None => "in this checkout",
    };
    match (global, project) {
        (false, false) => None,
        (true, false) => Some(format!(
            "Next: kendex check --global to list global packages; {} to refresh them.",
            command(true)?
        )),
        (false, true) => Some(format!(
            "Next: {} {} to refresh project packages.",
            command(false)?,
            checkout
        )),
        (true, true) => Some(format!(
            "Next: kendex check --global to list global packages; {} for global packages; {} {} for project packages.",
            command(true)?,
            command(false)?,
            checkout
        )),
    }
}

/// The bounded plain-text rendering for the session-start hook.
pub fn render_plain(report: &CheckReport) -> String {
    render(report, true)
}

/// The complete plain-text rendering for an explicit `kendex check`.
pub fn render_full(report: &CheckReport) -> String {
    render(report, false)
}

/// Empty when clean. Every bounded budget counts its own overflow line,
/// and no line is cut mid-way: command arguments remain complete.
fn render(report: &CheckReport, bounded: bool) -> String {
    if report.is_clean() {
        return String::new();
    }
    let mut lines: Vec<String> = Vec::new();
    for section in &report.sections {
        lines.push(format!("{}:", section.title));
        let over = bounded && section.lines.len() > SECTION_ITEMS;
        // The overflow line spends one of the section's own slots.
        let shown_count = match over {
            true => SECTION_ITEMS - 1,
            false => section.lines.len(),
        };
        for line in &section.lines[..shown_count] {
            match line.remedy.as_ref().and_then(|remedy| {
                Remedy::render(remedy, report.project_target.as_ref())
                    .map(|rendered| (remedy.mutates(), rendered))
            }) {
                Some((mutates, fix)) => {
                    // A remedy that only prints is what to see next, never
                    // the fix; and a fix this session cannot type is still
                    // the fix, marked with why it will not run here.
                    let word = match mutates {
                        true => "fix",
                        false => "see",
                    };
                    let (command, where_it_runs) = match &fix {
                        Fix::Here(command) => (command, ""),
                        Fix::Elsewhere(command) => (command, NOT_FROM_HERE),
                    };
                    lines.push(format!(
                        "  {} — {word}: {command}{where_it_runs}",
                        line.text
                    ));
                }
                None => lines.push(format!("  {}", line.text)),
            }
        }
        if over {
            lines.push(format!(
                "  … {} more — see: kendex check",
                section.lines.len() - shown_count
            ));
        }
    }
    if let Some(age) = report.snapshot_age_secs {
        lines.push(format!("(package evaluation: {} ago)", age_word(age)));
    }
    let action = next_action(report);

    if !bounded {
        if let Some(action) = action {
            lines.push(action);
        }
        return lines.join("\n") + "\n";
    }

    // Whole-report budgets, overflow line counted inside them: drop whole
    // lines from the end until the truncation line itself fits.
    let total = lines.len();
    let mut kept = lines.len();
    loop {
        let truncated = kept < total;
        let shown_lines = match truncated {
            true => kept.saturating_sub(1),
            false => kept,
        };
        let mut out: Vec<&str> = lines[..shown_lines].iter().map(String::as_str).collect();
        let note;
        if truncated {
            note = format!(
                "… report truncated ({} more line(s)) — see: kendex check",
                total - shown_lines
            );
            out.push(&note);
        }
        if let Some(action) = action.as_deref() {
            out.push(action);
        }
        let text = out.join("\n");
        if out.len() <= REPORT_LINES && text.len() <= REPORT_BYTES {
            return match text.is_empty() {
                true => text,
                false => text + "\n",
            };
        }
        if kept == 0 {
            return String::new();
        }
        kept -= 1;
    }
}
