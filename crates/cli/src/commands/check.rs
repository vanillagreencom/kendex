use std::process::ExitCode;

use kendex_core::drift::report::{self, CheckReport};
use kendex_core::env::Env;

use super::{answer, out, resolve_scopes};
mod commit_hooks;
use crate::scope::ScopeFilter;
use crate::ui;
use commit_hooks::fold_commit_hooks;

/// The session-start contract: exit 0 clean / 1 drift or not yet
/// evaluated / 2 could-not-check.
/// The report reads the drift snapshot and the fetch stamps — the deep work
/// already ran wherever updates, refresh, or apply last did — and spawns
/// one detached background refresh when any mirror is stale, so the next
/// session reads fresh verdicts. `--quiet` prints the bounded report and
/// nothing when clean; `--json` prints the machine shape.
pub fn run(
    env: &Env,
    filter: ScopeFilter,
    json: bool,
    quiet: bool,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let scopes = resolve_scopes(env, filter)?;
    let checked = {
        let _reading = ui::spinner("reading the snapshot");
        let mut checked = report::check(env, &scopes);
        fold_commit_hooks(env, &mut checked, &scopes);
        checked
    };

    // Freshness is earned in the background, never waited on. The spawn is
    // detached with no stdio; a busy or failing refresh writes stamps and
    // the next check reads them. `KENDEX_BACKGROUND_REFRESH=off` keeps the
    // check strictly read-only (tests, CI).
    if report::wants_background_refresh(env, &scopes)
        && std::env::var("KENDEX_BACKGROUND_REFRESH").as_deref() != Ok("off")
    {
        kendex_core::process::respawn_detached(&["source", "refresh", "--stale"]);
    }

    if json {
        answer(&serde_json::to_string_pretty(&checked)?);
    } else {
        render_text(&checked, quiet);
    }

    Ok(ExitCode::from(checked.status.exit_code()))
}

/// `--quiet` is the session hook's shape: the bounded report on stdout and
/// not one line beside it, so the framing and the closing verdict are for
/// the reader who ran the verb themselves.
fn render_text(checked: &CheckReport, quiet: bool) {
    if !quiet {
        ui::intro("kendex check");
    }
    let text = report::render_plain(checked);
    // The report is agent- and composition-facing content: stdout.
    for line in text.lines() {
        out(line);
    }
    if quiet {
        return;
    }
    ui::ledger(&verdict(checked, &text), &[]);
}

/// How the run ended, describing the report the reader was actually
/// shown. The renderer drops lines to fit its budgets, so a count taken
/// from the report rather than from the rendering claims items that never
/// reached the page; and the pointer to the lines above is named only
/// where EVERY counted line carries a remedy, since a pointer printed as
/// the answer to the whole count is a claim about all of it.
fn verdict(checked: &CheckReport, rendered: &str) -> String {
    // Clean is the report's answer, never the page's. The renderer drops
    // whole lines from the end to fit its budget, so a report carrying
    // findings can come out as a header and a truncation notice with
    // nothing indented under it — and reading emptiness off the page
    // would tell the reader everything matched while findings were cut.
    if checked.is_clean() {
        return "all clear — every install matches its source".to_owned();
    }
    let items: Vec<&str> = rendered
        .lines()
        .filter(|line| line.starts_with("  ") && !line.starts_with("  … and "))
        .collect();
    // Findings the page could not carry. The count still comes off what
    // was shown — a number the lines above cannot account for sends the
    // reader looking for items that are not there — so with nothing shown
    // there is no count to give, only the reason.
    if items.is_empty() {
        return "items need attention — the report above was truncated and names none of them"
            .to_owned();
    }
    let every = items
        .iter()
        .all(|line| line.contains(" — fix: ") || line.contains(" — see: "));
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
mod tests {
    use kendex_core::drift::report::{CheckReport, CheckStatus, Class, Line, Section};

    use super::verdict;

    fn reported(lines: Vec<&str>) -> CheckReport {
        CheckReport {
            status: CheckStatus::Drift,
            sections: vec![Section {
                title: "drift".to_owned(),
                lines: lines
                    .into_iter()
                    .map(|text| Line {
                        class: Class::Drift,
                        text: text.to_owned(),
                        remedy: None,
                    })
                    .collect(),
            }],
            snapshot_age_secs: None,
        }
    }

    /// The report decides whether the run is clean, not the page. A
    /// finding the renderer's budget dropped wholesale leaves nothing
    /// indented behind, and a verdict read off the page alone called that
    /// all clear while findings were cut.
    #[test]
    fn a_report_whose_findings_were_all_truncated_is_not_all_clear() {
        let truncated = "drift:\n  … and 3 more\n";
        let said = verdict(&reported(vec!["a", "b", "c"]), truncated);
        assert!(
            !said.contains("all clear"),
            "a truncated report read as clean: {said}"
        );
        assert!(said.contains("need attention"), "{said}");
        assert!(said.contains("truncated"), "{said}");
        // No count the page cannot account for.
        assert!(
            !said.contains('3'),
            "a count the page cannot support: {said}"
        );
    }

    /// A report with nothing in it is the only thing that reads as clean.
    #[test]
    fn an_empty_report_is_all_clear() {
        let empty = CheckReport {
            status: CheckStatus::Clean,
            sections: Vec::new(),
            snapshot_age_secs: None,
        };
        assert!(verdict(&empty, "").contains("all clear"));
    }

    /// What survived the page is still what the count is taken from.
    #[test]
    fn the_count_comes_off_the_lines_the_reader_saw() {
        let page = "drift:\n  one — fix: kendex apply\n  two — fix: kendex apply\n";
        let said = verdict(&reported(vec!["one", "two"]), page);
        assert!(said.starts_with("2 items need attention"), "{said}");
        assert!(said.contains("each line above says what to run"), "{said}");
    }
}
