//! A check report as a reader gets it: the [`Page`] the CLI draws an
//! explicit check from, and the bounded plain text the session hook prints,
//! which is spelled off that page.

use std::fmt;

use super::*;

/// Why a fix will not run where the report was read. Said once, here,
/// because this is the only place it is printed, and it names the
/// condition rather than a place to go instead: which session is free of
/// the hook is not something a report can know.
const NOT_FROM_HERE: &str = "(no --project-path form; the block-worktree-refresh hook refuses this verb inside a linked worktree)";

/// A duration as the shortest honest spelling: "3m", "5h", "2d".
fn age_word(secs: u64) -> String {
    match secs {
        s if s < 120 => "moments".to_owned(),
        s if s < 7200 => format!("{}m", s / 60),
        s if s < 172_800 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86_400),
    }
}

fn next_action(report: &CheckReport) -> Option<Sentence> {
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
        Some(ProjectTarget::MainCheckout(_)) => " in that checkout",
        Some(ProjectTarget::Worktree(_)) | None => " in this checkout",
    };
    let next = Sentence::default().prose("Next: ");
    Some(match (global, project) {
        (false, false) => return None,
        (true, false) => next
            .command("kendex check --global")
            .prose(" to list global packages; ")
            .command(&command(true)?)
            .prose(" to refresh them."),
        (false, true) => next
            .command(&command(false)?)
            .prose(checkout)
            .prose(" to refresh project packages."),
        (true, true) => next
            .command("kendex check --global")
            .prose(" to list global packages; ")
            .command(&command(true)?)
            .prose(" for global packages; ")
            .command(&command(false)?)
            .prose(checkout)
            .prose(" for project packages."),
    })
}

/// A report as its complete rendering shows it: every item with the remedy
/// it offers, then the evaluation age and the next step. The CLI draws an
/// explicit check from this, and [`render_plain`] spells the session hook's
/// bounded report off it, so the two cannot disagree about which item
/// offers which command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Page {
    pub sections: Vec<PageSection>,
    /// `(package evaluation: 5m ago)`, where anything was evaluated.
    pub age: Option<String>,
    /// The refresh a reader runs next, where every line points at one.
    pub next: Option<Sentence>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PageSection {
    pub title: String,
    pub items: Vec<PageItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PageItem {
    pub class: Class,
    pub text: Sentence,
    pub fix: Option<PageFix>,
}

/// The remedy an item offers, as a reader acts on it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PageFix {
    /// A remedy that only prints is what to see next, never the fix.
    pub mutates: bool,
    pub fix: Fix,
}

impl PageFix {
    /// `fix: <command>` or `see: <command>`: the part a reader copies, which
    /// no rendering may break.
    pub fn command_line(&self) -> String {
        let word = match self.mutates {
            true => "fix",
            false => "see",
        };
        match &self.fix {
            Fix::Here(command) | Fix::Elsewhere(command) => format!("{word}: {command}"),
        }
    }

    /// Why a fix this session cannot type will not run here. It is still
    /// the fix.
    pub fn remark(&self) -> Option<&'static str> {
        match self.fix {
            Fix::Here(_) => None,
            Fix::Elsewhere(_) => Some(NOT_FROM_HERE),
        }
    }
}

impl fmt::Display for PageFix {
    /// The command line, then the remark where there is one.
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.remark() {
            Some(remark) => write!(out, "{} {remark}", self.command_line()),
            None => out.write_str(&self.command_line()),
        }
    }
}

impl PageItem {
    /// The item's plain line, without the indent that makes it detail of
    /// its section.
    pub fn line(&self) -> String {
        match &self.fix {
            Some(fix) => format!("{} — {fix}", self.text),
            None => self.text.to_string(),
        }
    }
}

/// Empty when clean: no section, and no age or next step to go with none.
pub fn page(report: &CheckReport) -> Page {
    if report.is_clean() {
        return Page {
            sections: Vec::new(),
            age: None,
            next: None,
        };
    }
    let sections = report
        .sections
        .iter()
        .map(|section| PageSection {
            title: section.title.clone(),
            items: section
                .lines
                .iter()
                .map(|line| PageItem {
                    class: line.class,
                    text: line.text.clone(),
                    fix: line.remedy.as_ref().and_then(|remedy| {
                        Remedy::render(remedy, report.project_target.as_ref()).map(|fix| PageFix {
                            mutates: remedy.mutates(),
                            fix,
                        })
                    }),
                })
                .collect(),
        })
        .collect();
    Page {
        sections,
        age: report
            .snapshot_age_secs
            .map(|age| format!("(package evaluation: {} ago)", age_word(age))),
        next: next_action(report),
    }
}

/// The bounded plain-text rendering for the session-start hook. Empty when
/// clean. Every budget counts its own overflow line, and no line is cut
/// mid-way: command arguments remain complete.
pub fn render_plain(report: &CheckReport) -> String {
    if report.is_clean() {
        return String::new();
    }
    let page = page(report);
    let mut lines: Vec<String> = Vec::new();
    for section in &page.sections {
        lines.push(format!("{}:", section.title));
        let over = section.items.len() > SECTION_ITEMS;
        // The overflow line spends one of the section's own slots.
        let shown_count = match over {
            true => SECTION_ITEMS - 1,
            false => section.items.len(),
        };
        for item in &section.items[..shown_count] {
            lines.push(format!("  {}", item.line()));
        }
        if over {
            lines.push(format!(
                "  … {} more — see: kendex check",
                section.items.len() - shown_count
            ));
        }
    }
    lines.extend(page.age);
    let action = page.next.map(|next| next.to_string());

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
