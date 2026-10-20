use std::process::ExitCode;

use kendex_core::drift::report::{
    self, CheckReport, CheckStatus, Class, Page, PageSection, Sentence, Verbosity,
};
use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::{answer, out, resolve_scopes};
mod commit_hooks;
use crate::scope::ScopeFilter;
use crate::ui::{self, Channel, Span, Status, Style, Value};
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
/// prints the machine shape. `--verbose` adds each line's technical cause. `mode` is whether that deep read may write a
/// project's committed install record: `--report-only`, which the session
/// hook passes, never does.
pub fn run(
    env: &Env,
    filter: ScopeFilter,
    json: bool,
    quiet: bool,
    verbosity: Verbosity,
    mode: kendex_core::drift::copies::CheckMode,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let scopes = resolve_scopes(env, filter)?;
    let channel = ui::channel(json);
    let mut checked = {
        let _reading = match (&channel, quiet) {
            (Channel::Human(style), false) => {
                Some(ui::Spinner::start(style, "reading the snapshot"))
            }
            (Channel::Human(_), true) | (Channel::Json, _) => None,
        };
        let mut checked = report::check_with_refusals(env, &scopes, mode, |error| {
            if matches!(
                error,
                kendex_core::error::CoreError::LockCorrupt { .. }
                    | kendex_core::error::CoreError::LegacyProjectLock { .. }
            ) {
                ui::stderr(&[ui::escaped(&error.to_string())]);
            }
        });
        fold_commit_hooks(env, &mut checked, &scopes);
        checked
    };

    // Freshness is earned in the background, never waited on. The spawn is
    // detached with no stdio; a busy or failing refresh writes stamps and
    // the next check reads them, and a plan over unrecorded copies the
    // deadline cut short is finished there. `KENDEX_BACKGROUND_REFRESH=off`
    // suppresses this spawn alone (tests, CI), and with it that finish;
    // the check's other write, the install record for a copy it proved
    // against its source, is the report's own, and `--report-only`
    // withholds it at a project scope.
    let background_disabled = std::env::var("KENDEX_BACKGROUND_REFRESH").as_deref() == Ok("off");
    let requested =
        !background_disabled && report::wants_background_refresh(env, &scopes, &checked);
    if requested {
        kendex_core::process::respawn_detached(&["source", "refresh", "--stale"]);
    }
    for line in checked
        .sections
        .iter_mut()
        .flat_map(|section| &mut section.lines)
    {
        if line.class == Class::Settling {
            let observation = if background_disabled {
                "; background refresh disabled"
            } else if requested {
                "; refresh requested; running state unconfirmed"
            } else {
                "; refresh running state unconfirmed"
            };
            line.text = line.text.clone().prose(observation);
        }
    }

    match (channel, quiet) {
        (Channel::Json, _) => answer(&serde_json::to_string_pretty(&checked)?),
        // The session hook's shape: the bounded report on stdout and not
        // one line beside it. It is agent-facing text with its own budgets,
        // not a rendering of the components.
        (Channel::Human(_), true) => {
            for line in report::render_plain(&checked, verbosity).lines() {
                out(line);
            }
        }
        (Channel::Human(style), false) => draw(&style, &checked, &scopes, verbosity),
    }

    Ok(ExitCode::from(checked.status.exit_code()))
}

/// The explicit check, drawn: the report is agent- and composition-facing,
/// so it goes to stdout; the header and the verdict are about the run, and
/// go to stderr.
fn draw(style: &Style, checked: &CheckReport, scopes: &[Scope], verbosity: Verbosity) {
    let target: Vec<String> = scopes.iter().map(Scope::label).collect();
    let screen = screen(style, checked, &target.join(", "), verbosity);
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
fn screen(style: &Style, checked: &CheckReport, target: &str, verbosity: Verbosity) -> Screen {
    let page = report::page(checked, verbosity);
    let mut report = Vec::new();
    for section in &page.sections {
        report.extend(style.section(&section.title, section.items.len(), section_status(section)));
        for item in &section.items {
            let copy = item.fix.as_ref().map(|fix| fix.command_line());
            let value = item
                .fix
                .as_ref()
                .zip(copy.as_deref())
                .map(|(fix, copy)| Value {
                    copy,
                    remark: fix.remark(),
                });
            report.extend(style.row(status(item.class), &spans(&item.text), value));
            if let Some(detail) = &item.detail {
                report.extend(style.detail(None, &[Span::Verbatim(detail)]));
            }
        }
    }
    if let Some(age) = &page.age {
        report.extend(style.note(&[Span::Prose(age)]));
    }
    if let Some(next) = &page.next {
        report.extend(style.note(&spans(next)));
    }
    let verdict = verdict(checked, &page, verbosity);
    // A check with nothing to draw and no verdict to close on is silent:
    // a header over nothing would be a line about nothing.
    let head = match report.is_empty() && verdict.is_none() {
        true => Vec::new(),
        false => style.header("check", target),
    };
    Screen {
        head,
        report,
        verdict: verdict
            .map(|(status, text)| style.summary(status, &text))
            .unwrap_or_default(),
    }
}

/// A report sentence as the components take it, its commands still marked.
fn spans(sentence: &Sentence) -> Vec<Span<'_>> {
    sentence.spans().into_iter().map(Span::from).collect()
}

/// Drift wants the reader's decision, a verdict still owed is a notice,
/// and a line the check could not produce is a failure.
fn status(class: Class) -> Status {
    match class {
        Class::Drift => Status::Decision,
        Class::Unevaluated | Class::Settling | Class::Notice => Status::Notice,
        Class::Unknown => Status::Failed,
    }
}

/// Pending comparisons need a notice even though their exit stays non-clean.
fn section_status(section: &PageSection) -> Status {
    if section
        .items
        .iter()
        .any(|item| item.class == Class::Unknown)
    {
        Status::Failed
    } else if section
        .items
        .iter()
        .any(|item| matches!(item.class, Class::Drift | Class::Unevaluated))
    {
        Status::Decision
    } else {
        Status::Notice
    }
}

/// What a check's status says to its reader: clean is done, drift wants a
/// decision, and a check that could not finish failed.
fn outcome(status: CheckStatus) -> Status {
    match status {
        CheckStatus::Clean => Status::Done,
        CheckStatus::Drift => Status::Decision,
        CheckStatus::Unknown => Status::Failed,
    }
}

/// Pending comparisons are counted separately from attention in every view.
fn verdict(checked: &CheckReport, page: &Page, _verbosity: Verbosity) -> Option<(Status, String)> {
    let all = || page.sections.iter().flat_map(|section| &section.items);
    let settling = all().filter(|item| item.class == Class::Settling).count();
    let notices = all().any(|item| item.class == Class::Notice);
    let pending = format!(
        "{settling} item{} pending evaluation",
        if settling == 1 { "" } else { "s" }
    );
    let items: Vec<_> = all()
        .filter(|item| !matches!(item.class, Class::Settling | Class::Notice))
        .collect();
    if items.is_empty() {
        return Some(if settling > 0 {
            (
                Status::Notice,
                if notices {
                    format!("{pending}; external command notices are listed above")
                } else {
                    pending
                },
            )
        } else if notices {
            (
                Status::Notice,
                "external command notices are listed above".to_owned(),
            )
        } else {
            (
                Status::Done,
                "all clear — every install matches its source".to_owned(),
            )
        });
    }
    let every = items.iter().all(|item| item.fix.is_some());
    let text = format!(
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
    );
    let text = if settling > 0 {
        format!("{text}; {pending}")
    } else {
        text
    };
    Some((outcome(checked.status), text))
}

#[cfg(test)]
mod tests;
