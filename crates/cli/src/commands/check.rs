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
/// already ran wherever updates, refresh, or apply last did — with one
/// deep read of its own, budgeted and memoized, for a declaration sitting
/// on files no record accounts for; and it spawns one detached background
/// refresh when any mirror is stale, a scope has no snapshot, or that read
/// is still owed, so the next session reads fresh verdicts. An explicit
/// check prints every line. `--quiet` prints the bounded session report and
/// nothing when clean. `--json` prints the machine shape.
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
    let text = rendered_text(checked, quiet);
    // The report is agent- and composition-facing content: stdout.
    for line in text.lines() {
        out(line);
    }
    if quiet {
        return;
    }
    ui::ledger(&verdict(checked, &text), &[]);
}

fn rendered_text(checked: &CheckReport, quiet: bool) -> String {
    match quiet {
        true => report::render_plain(checked),
        false => report::render_full(checked),
    }
}

/// How the run ended, describing the complete report above it. The pointer
/// to those lines is named only where every counted line has a remedy.
fn verdict(checked: &CheckReport, rendered: &str) -> String {
    if checked.is_clean() {
        return "all clear — every install matches its source".to_owned();
    }
    let items: Vec<&str> = rendered
        .lines()
        .filter(|line| line.starts_with("  "))
        .collect();
    assert!(
        !items.is_empty(),
        "a non-clean complete check report must contain an item line"
    );
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

    use super::{rendered_text, verdict};

    fn reported<T: Into<String>>(lines: Vec<T>) -> CheckReport {
        CheckReport {
            status: CheckStatus::Drift,
            sections: vec![Section {
                title: "drift".to_owned(),
                lines: lines
                    .into_iter()
                    .map(|text| Line {
                        class: Class::Drift,
                        text: text.into(),
                        remedy: None,
                    })
                    .collect(),
            }],
            snapshot_age_secs: None,
            project_target: None,
            deep_pass_owed: false,
        }
    }

    /// A report with nothing in it reads as clean.
    #[test]
    fn an_empty_report_is_all_clear() {
        let empty = CheckReport {
            status: CheckStatus::Clean,
            sections: Vec::new(),
            snapshot_age_secs: None,
            project_target: None,
            deep_pass_owed: false,
        };
        assert!(verdict(&empty, "").contains("all clear"));
    }

    /// The complete report's item lines determine the count.
    #[test]
    fn the_count_comes_off_the_lines_the_reader_saw() {
        let page = "drift:\n  one — fix: kendex apply\n  two — fix: kendex apply\n";
        let said = verdict(&reported(vec!["one", "two"]), page);
        assert!(said.starts_with("2 items need attention"), "{said}");
        assert!(said.contains("each line above says what to run"), "{said}");
    }

    #[test]
    fn an_explicit_check_prints_every_item_while_the_session_hook_stays_bounded() {
        let report = reported((0..12).map(|i| format!("item-{i}")).collect());

        let hook = rendered_text(&report, true);
        assert!(hook.contains("see: kendex check"), "{hook}");
        assert!(!hook.contains("item-11"), "{hook}");

        let explicit = rendered_text(&report, false);
        assert!(explicit.contains("item-11"), "{explicit}");
        assert!(!explicit.contains("more — see:"), "{explicit}");
    }
}
