use std::process::ExitCode;

use kendex_core::drift::report::{self, CheckReport};
use kendex_core::env::Env;

use super::{out, resolve_scopes};
use crate::scope::ScopeFilter;
use crate::ui;

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
        out(&serde_json::to_string_pretty(&checked)?);
    } else {
        render_text(&checked, quiet);
    }

    Ok(ExitCode::from(checked.status.exit_code()))
}

/// Whether commits here are actually gated. The one thing this report
/// cannot read off a stat: the shims live in `.git/hooks`, which no lock
/// tracks, and a repository whose shims drifted looks identical on disk to
/// one that never armed any.
///
/// The verdict is the package's own `install-git-hooks --check`, and its
/// summary line is folded whole. kendex used to read the hook files itself
/// here, with a second grammar for what "armed" means; the two never agreed
/// for long, and the disagreement showed up as a session-start report
/// contradicting the gate that actually runs.
///
/// This runs a script out of a checkout, unattended, at every session start
/// — so what may run it is the question the rest of this is about.
///
/// The license is `guard::locally_armed`: the helper the installer leaves
/// in the hooks directory, which git clones for nobody. Its presence is a
/// local act by whoever owns this machine, and it is the same act that put
/// the checkout's scripts on every commit here. Cloning a repository and
/// asking after its status therefore executes none of its code, whatever
/// the repository ships.
///
/// The install record is NOT that license and never was: `.kendex-lock.json`
/// sits under the work tree and arrives with the fetch, so a checkout can
/// write one declaring anything. It answers a different question — whether
/// this project asked for a commit gate — and so decides only whether an
/// unarmed repository hears about it, which is wording.
///
/// Only project scopes have a work tree to ask about. A verdict that could
/// not be taken is `could not check`, never a silent pass.
fn fold_commit_hooks(env: &Env, checked: &mut CheckReport, scopes: &[kendex_core::model::Scope]) {
    use kendex_core::drift::report::{Class, Text};
    use kendex_core::model::Scope;
    for scope in scopes {
        let Scope::Project { root } = scope.canonical() else {
            continue;
        };
        // A checkout that merely carries the files is not missing an arming
        // nobody asked for. Asked before the probe: both cost git
        // processes, and this runs at every session start.
        if !installed_here(env, scope) {
            continue;
        }
        // No repository here is no verdict: there is nothing to arm and no
        // drift to report. Folding it into "not armed" told a scope with no
        // work tree to run `kendex guard install`, which exits 2 there —
        // advice that cannot be taken, every session. The installer's own
        // refusal is exit 2, so asking it would report could-not-check
        // there for ever instead.
        let repo = match kendex_core::guard::Repo::probe(&root) {
            Ok(Some(repo)) => repo,
            Ok(None) => continue,
            Err(error) => {
                report::fold(
                    checked,
                    "commit hooks",
                    Class::Unknown,
                    Text::Foreign(error.to_string()),
                );
                continue;
            }
        };
        // Nobody armed this repository, so nothing here is ours to run and
        // there is nothing for the package to describe. kendex says the one
        // thing it knows from local state alone, and names the command that
        // both arms the gate and licenses every later reading of it.
        if !kendex_core::guard::locally_armed(&repo) {
            report::fold(
                checked,
                "commit hooks",
                Class::Drift,
                Text::Own(format!(
                    "commit hooks are not armed in {} — `kendex guard install` arms them, and `kendex guard check` says more",
                    root.display()
                )),
            );
            continue;
        }
        let (class, text) = match kendex_core::guard::check_repo(&repo) {
            Ok(report) if report.code == 0 => continue,
            Ok(report) => verdict_of(&report),
            // A declaration with nothing to run is a missing render, not an
            // absent install: the lock already records the package, so
            // `kendex add` would be advice about a state the reader is not
            // in. It is drift with a remedy, which is what it was before
            // this fold delegated, and never a check that could not be
            // taken.
            Err(error) => match kendex_core::guard::installer_missing(&repo) {
                true => (
                    Class::Drift,
                    Text::Own(format!(
                        "{} is declared in {} but its scripts are not there, so every commit fails — `kendex refresh` renders it again",
                        kendex_core::guard::SKILL,
                        root.display()
                    )),
                ),
                false => (Class::Unknown, Text::Foreign(error.to_string())),
            },
        };
        report::fold(checked, "commit hooks", class, text);
    }
}

/// How long a relayed verdict may be before kendex declines to print it.
///
/// The package writes one summary line whose length is its own prose plus
/// the hooks directory, and the longest it has runs to about 400
/// characters. This is well clear of that and nowhere near the report's
/// own 8 KB. It exists so a script that answers with a megabyte cannot put
/// a megabyte into `--json`.
const VERDICT_CHARS: usize = 2000;

/// The package's verdict as a report line: its class, and its own sentence.
///
/// The sentence is folded as `Text::Own` and therefore never cut, which is
/// the point. Its remedy is the END of it — `run 'kendex guard install' to
/// re-arm` — so the fragment bounding that `Text::Foreign` applies took the
/// remedy off every line long enough to need one. What bounds it instead is
/// the whole-report budget, which drops a line entire rather than half of
/// it, and [`VERDICT_CHARS`] above that: too long to show is said in
/// kendex's own words, never as a sentence stopping mid-remedy.
///
/// A summary line is the one thing the package promises on stdout, and it
/// promises it only once `--check` has run. Nothing there means the script
/// died before reaching it — a usage refusal, or `set -e` on a library it
/// could not source — and that is a check that could not be taken however
/// it exited. Reading such an exit 1 as the package's "not armed" verdict
/// would present a script that never ran as a taken measurement.
fn verdict_of(
    report: &kendex_core::guard::GuardReport,
) -> (
    kendex_core::drift::report::Class,
    kendex_core::drift::report::Text,
) {
    use kendex_core::drift::report::{Class, Text};
    let said = report.stdout.join(" ");
    let said = said.trim();
    if said.is_empty() {
        // The diagnostics are the package's and unbounded, so they go in
        // the position a cut costs nothing: after the sentence that says
        // what happened.
        return (
            Class::Unknown,
            Text::Foreign(format!(
                "the {} installer exited {} with no verdict, so commit hooks could not be checked: {}",
                kendex_core::guard::SKILL,
                report.code,
                report.stderr.join(" ").trim()
            )),
        );
    }
    let class = match report.code {
        1 => Class::Drift,
        _ => Class::Unknown,
    };
    match said.chars().count() > VERDICT_CHARS {
        true => (
            class,
            Text::Own(format!(
                "the {} installer answered about {} with {} characters, too long to relay — run `kendex guard check` to read it",
                kendex_core::guard::SKILL,
                said.chars().take(60).collect::<String>(),
                said.chars().count()
            )),
        ),
        false => (class, Text::Own(said.to_owned())),
    }
}

/// Whether this project's install record carries the guard package — the
/// difference between "your hooks are not armed" and a clone that simply
/// ships the files.
///
/// It is one of two conditions the fold above requires before it launches
/// the package's script, so widening it widens what `kendex check` runs
/// unattended. It is the weaker of the two by design and cannot stand
/// alone: this file arrives with the fetch, so a checkout can write one
/// saying anything, and `guard::locally_armed` is what a checkout cannot
/// forge. Narrowing execution further is safe; loosening this without
/// reading that one is not.
fn installed_here(env: &Env, scope: &kendex_core::model::Scope) -> bool {
    kendex_core::lock::load(&kendex_core::lock::lock_path(env, scope)).is_ok_and(|lock| {
        // Enabled, not merely recorded: a declaration switched off is
        // someone saying they do not want this gate here, and reporting it
        // as unarmed drift every session start argues with them about a
        // choice they already made.
        //
        // And the SKILL of that name, not anything of that name. A name is
        // not unique across kinds — an agent called growth-guards is a
        // legal thing to install — and reading one as consent to a commit
        // gate reports hook drift, every session, at a project that never
        // asked for hooks and has no way to make the report stop.
        lock.entries.values().any(|entry| {
            entry.name == kendex_core::guard::SKILL
                && entry.kind == kendex_core::model::ItemKind::Skill
                && entry.enabled
        })
    })
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
    fn the_count_comes_off_the_lines_the_reader_was_shown() {
        let page = "drift:\n  one — fix: kendex apply\n  two — fix: kendex apply\n";
        let said = verdict(&reported(vec!["one", "two"]), page);
        assert!(said.starts_with("2 items need attention"), "{said}");
        assert!(said.contains("each line above says what to run"), "{said}");
    }
}
