//! The bounded plain-text rendering of a check report.

use super::*;

/// A duration as the shortest honest spelling: "3m", "5h", "2d".
fn age_word(secs: u64) -> String {
    match secs {
        s if s < 120 => "moments".to_owned(),
        s if s < 7200 => format!("{}m", s / 60),
        s if s < 172_800 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86_400),
    }
}

/// The bounded plain-text rendering — what the session-start hook prints
/// into agent context. Empty when clean. Every budget counts its own
/// overflow line inside itself, and no line is ever cut mid-way: command
/// arguments are never truncated.
pub fn render_plain(report: &CheckReport) -> String {
    if report.is_clean() {
        return String::new();
    }
    let mut lines: Vec<String> = Vec::new();
    for section in &report.sections {
        lines.push(format!("{}:", section.title));
        let over = section.lines.len() > SECTION_ITEMS;
        // The overflow line spends one of the section's own slots.
        let shown_count = match over {
            true => SECTION_ITEMS - 1,
            false => section.lines.len(),
        };
        for line in &section.lines[..shown_count] {
            match line.remedy.as_ref().and_then(|remedy| {
                Remedy::render(remedy).map(|rendered| (remedy.mutates(), rendered))
            }) {
                Some((true, remedy)) => lines.push(format!("  {} — fix: {remedy}", line.text)),
                Some((false, remedy)) => lines.push(format!("  {} — see: {remedy}", line.text)),
                None => lines.push(format!("  {}", line.text)),
            }
        }
        if over {
            lines.push(format!(
                "  … and {} more",
                section.lines.len() - shown_count
            ));
        }
    }
    if let Some(age) = report.snapshot_age_secs {
        lines.push(format!("(checked against sources {} ago)", age_word(age)));
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
            note = format!("… report truncated ({} more line(s))", total - shown_lines);
            out.push(&note);
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
