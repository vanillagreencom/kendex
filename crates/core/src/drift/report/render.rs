//! A check report as a reader gets it: the [`Page`] the CLI draws an
//! explicit check from, and the bounded plain text the session hook prints,
//! which is spelled off that page.

use std::fmt;

use super::*;

/// Why a fix will not run where the report was read. Said once, here,
/// because this is the only place it is printed, and it names the
/// condition rather than a place to go instead: which session is free of
/// the hook is not something a report can know.
const NOT_FROM_HERE: &str = "(the main checkout's project: its refresh owner runs this there; the block-worktree-refresh hook refuses it from a linked worktree)";

/// How much of a report a reader asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verbosity {
    /// What a person must act on or know: no line the background refresh
    /// settles, no technical detail, and in the session report a count and
    /// one example per section.
    Default,
    /// Every line, each with its technical detail.
    Verbose,
}

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
            Some(Fix::Here(command) | Fix::Elsewhere(command)) => Some(format!("{command} --yes")),
            None => None,
        };
    // The main checkout's refresh is its refresh owner's, run there: the
    // hook refuses it from this worktree.
    let checkout = match report.project_target {
        Some(ProjectTarget::MainCheckout(_)) => " from the main checkout, as its refresh owner,",
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
    /// The line's technical cause, under [`Verbosity::Verbose`] only.
    pub detail: Option<String>,
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

/// Empty when nothing is left to show: no section, and no age or next step
/// to go with none.
pub fn page(report: &CheckReport, verbosity: Verbosity) -> Page {
    let verbose = verbosity == Verbosity::Verbose;
    let sections: Vec<PageSection> = report
        .sections
        .iter()
        .map(|section| PageSection {
            title: section.title.clone(),
            items: section
                .lines
                .iter()
                .filter(|line| verbose || line.class != Class::Settling)
                .map(|line| PageItem {
                    class: line.class,
                    text: line.text.clone(),
                    fix: line.remedy.as_ref().and_then(|remedy| {
                        Remedy::render(remedy, report.project_target.as_ref()).map(|fix| PageFix {
                            mutates: remedy.mutates(),
                            fix,
                        })
                    }),
                    detail: line.detail.clone().filter(|_| verbose),
                })
                .collect(),
        })
        .filter(|section| !section.items.is_empty())
        .collect();
    if sections.is_empty() {
        return Page {
            sections,
            age: None,
            next: None,
        };
    }
    Page {
        sections,
        age: report
            .snapshot_age_secs
            .map(|age| format!("(package evaluation: {} ago)", age_word(age))),
        next: next_action(report),
    }
}

/// One line saying how the check ended, over the items the page shows.
fn outcome(page: &Page) -> String {
    let items = || page.sections.iter().flat_map(|section| &section.items);
    let count = |class: &[Class]| items().filter(|item| class.contains(&item.class)).count();
    let items_word = |n: usize| match n {
        1 => "1 item".to_owned(),
        n => format!("{n} items"),
    };
    let attention = count(&[Class::Drift, Class::Unevaluated]);
    let unknown = count(&[Class::Unknown]);
    let settling = count(&[Class::Settling]);
    let mut said = Vec::new();
    if attention > 0 {
        let verb = match attention {
            1 => "needs",
            _ => "need",
        };
        said.push(format!("{} {verb} attention", items_word(attention)));
    }
    if unknown > 0 {
        said.push(format!("kendex could not check {}", items_word(unknown)));
    }
    if settling > 0 {
        said.push(format!(
            "the background refresh checks {} again",
            items_word(settling)
        ));
    }
    let said = said.join("; ");
    let mut said = said.chars();
    match said.next() {
        Some(first) => format!("{}{}.", first.to_uppercase(), said.as_str()),
        None => String::new(),
    }
}

/// The bounded plain-text rendering for the session-start hook. Empty when
/// nothing is left to show. By default each section is its title with the
/// item count, one example and how many more there are, then one outcome
/// line and the next step; [`Verbosity::Verbose`] lists every item with its
/// technical detail. Every budget counts its own overflow line, and no line
/// is cut mid-way: command arguments remain complete.
pub fn render_plain(report: &CheckReport, verbosity: Verbosity) -> String {
    let page = page(report, verbosity);
    if page.sections.is_empty() {
        return String::new();
    }
    let mut lines: Vec<String> = Vec::new();
    for (at, section) in page.sections.iter().enumerate() {
        if at > 0 {
            lines.push(String::new());
        }
        lines.push(format!("{}: {}", section.title, section.items.len()));
        // By default one example and the count of the rest; verbose lists
        // up to the section budget, the overflow line spending one of its
        // slots.
        let shown_count = match verbosity {
            Verbosity::Default => section.items.len().min(1),
            Verbosity::Verbose if section.items.len() > SECTION_ITEMS => SECTION_ITEMS - 1,
            Verbosity::Verbose => section.items.len(),
        };
        for item in &section.items[..shown_count] {
            lines.push(format!("  {}", item.line()));
            lines.extend(item.detail.iter().map(|detail| format!("    {detail}")));
        }
        if shown_count < section.items.len() {
            lines.push(format!(
                "  … {} more — see: kendex check",
                section.items.len() - shown_count
            ));
        }
    }
    lines.extend(page.age.clone());
    let tail: Vec<String> = std::iter::once(outcome(&page))
        .chain(page.next.map(|next| next.to_string()))
        .collect();

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
        out.extend(tail.iter().map(String::as_str));
        let text = out.join("\n");
        if out.len() <= REPORT_LINES && text.len() <= REPORT_BYTES {
            return text + "\n";
        }
        if kept == 0 {
            return String::new();
        }
        kept -= 1;
    }
}
