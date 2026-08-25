use std::process::ExitCode;

use kendex_core::drift::report::{self, CheckReport};
use kendex_core::env::Env;

use super::{out, resolve_scopes, say};
use crate::scope::ScopeFilter;

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
    let checked = report::check(env, &scopes);

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

fn render_text(checked: &CheckReport, quiet: bool) {
    let text = report::render_plain(checked);
    if text.is_empty() {
        if !quiet {
            say("all clear — nothing stale, nothing awaiting review");
        }
        return;
    }
    // The report is agent- and composition-facing content: stdout.
    for line in text.lines() {
        out(line);
    }
}
