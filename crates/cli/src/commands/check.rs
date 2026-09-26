use std::process::ExitCode;

use kendex_core::drift::report::{self, CheckReport, CheckStatus, Class, Page, PageSection};
use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::{answer, out, resolve_scopes};
mod commit_hooks;
use crate::scope::ScopeFilter;
use crate::ui::{self, Channel, Status, Style};
use commit_hooks::fold_commit_hooks;

/// The session-start contract: exit 0 clean / 1 drift or not yet
/// evaluated / 2 could-not-check.
/// The report reads the drift snapshot and the fetch stamps — the deep work
/// already ran wherever updates, refresh, or apply last did — with one
/// deep read of its own, budgeted and memoized, for a declaration sitting
/// on files no record accounts for; and it spawns one detached background
/// refresh when any mirror is stale, a scope has no snapshot, or that read
/// is still owed, so the next session reads fresh verdicts. An explicit
/// check draws every line from the design system's components. `--quiet`
/// prints the bounded session report and nothing when clean. `--json`
/// prints the machine shape.
pub fn run(
    env: &Env,
    filter: ScopeFilter,
    json: bool,
    quiet: bool,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let scopes = resolve_scopes(env, filter)?;
    let channel = ui::channel(json);
    let checked = {
        let _reading = match (&channel, quiet) {
            (Channel::Human(style), false) => {
                Some(ui::Spinner::start(style, "reading the snapshot"))
            }
            (Channel::Human(_), true) | (Channel::Json, _) => None,
        };
        let mut checked = report::check(env, &scopes);
        fold_commit_hooks(env, &mut checked, &scopes);
        checked
    };

    // Freshness is earned in the background, never waited on. The spawn is
    // detached with no stdio; a busy or failing refresh writes stamps and
    // the next check reads them, and a plan over unrecorded copies the
    // deadline cut short is finished there. `KENDEX_BACKGROUND_REFRESH=off`
    // suppresses this spawn alone (tests, CI), and with it that finish;
    // the check's other write, the install record for a copy it proved
    // against its source, is the report's own.
    if report::wants_background_refresh(env, &scopes, &checked)
        && std::env::var("KENDEX_BACKGROUND_REFRESH").as_deref() != Ok("off")
    {
        kendex_core::process::respawn_detached(&["source", "refresh", "--stale"]);
    }

    match (channel, quiet) {
        (Channel::Json, _) => answer(&serde_json::to_string_pretty(&checked)?),
        // The session hook's shape: the bounded report on stdout and not
        // one line beside it. It is agent-facing text with its own budgets,
        // not a rendering of the components.
        (Channel::Human(_), true) => {
            for line in report::render_plain(&checked).lines() {
                out(line);
            }
        }
        (Channel::Human(style), false) => draw(&style, &checked, &scopes),
    }

    Ok(ExitCode::from(checked.status.exit_code()))
}

/// The explicit check, drawn: the report is agent- and composition-facing,
/// so it goes to stdout; the header and the verdict are about the run, and
/// go to stderr.
fn draw(style: &Style, checked: &CheckReport, scopes: &[Scope]) {
    let target: Vec<String> = scopes.iter().map(Scope::label).collect();
    let screen = screen(style, checked, &target.join(", "));
    ui::stderr(&screen.head);
    ui::stdout(&screen.report);
    ui::stderr(&screen.verdict);
}

/// What an explicit check draws, stream by stream.
struct Screen {
    head: Vec<String>,
    report: Vec<String>,
    verdict: Vec<String>,
}

/// The explicit check from the components: a header naming what was
/// checked, one section per kind of finding with a row per item, the
/// evaluation age and the next step, and the verdict.
fn screen(style: &Style, checked: &CheckReport, target: &str) -> Screen {
    let page = report::page(checked);
    let mut report = Vec::new();
    for section in &page.sections {
        report.extend(style.section(&section.title, section.items.len(), section_status(section)));
        for item in &section.items {
            let fix = item.fix.as_ref().map(ToString::to_string);
            report.extend(style.row(status(item.class), &item.text, fix.as_deref()));
        }
    }
    for footnote in page.age.iter().chain(&page.next) {
        report.extend(style.note(footnote));
    }
    let outcome = match checked.status {
        CheckStatus::Clean => Status::Done,
        CheckStatus::Drift => Status::Decision,
        CheckStatus::Unknown => Status::Failed,
    };
    Screen {
        head: style.header("check", target),
        report,
        verdict: style.summary(outcome, &verdict(&page)),
    }
}

/// Drift wants the reader's decision, a verdict still owed is a notice,
/// and a line the check could not produce is a failure.
fn status(class: Class) -> Status {
    match class {
        Class::Drift => Status::Decision,
        Class::Unevaluated => Status::Notice,
        Class::Unknown => Status::Failed,
    }
}

/// A section is as serious as its most serious row.
fn section_status(section: &PageSection) -> Status {
    let worst = section
        .items
        .iter()
        .map(|item| item.class)
        .max_by_key(|class| match class {
            Class::Unevaluated => 0,
            Class::Drift => 1,
            Class::Unknown => 2,
        });
    match worst {
        Some(class) => status(class),
        None => unreachable!("a report section holds at least one line"),
    }
}

/// How the run ended, describing the complete report above it. The pointer
/// to those lines is named only where every counted line has a remedy.
fn verdict(page: &Page) -> String {
    let items: Vec<_> = page
        .sections
        .iter()
        .flat_map(|section| &section.items)
        .collect();
    if items.is_empty() {
        return "all clear — every install matches its source".to_owned();
    }
    let every = items.iter().all(|item| item.fix.is_some());
    format!(
        "{} item{} need{} attention{}",
        items.len(),
        match items.len() {
            1 => "",
            _ => "s",
        },
        match items.len() {
            1 => "s",
            _ => "",
        },
        match every {
            true => " — each line above says what to run",
            false => " — see the lines above",
        }
    )
}

#[cfg(test)]
mod tests;
